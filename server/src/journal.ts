import type { Db } from './db.js';
import type { Devices } from './devices.js';

export const MAX_BATCH_BYTES = 4 * 1024 * 1024;
export const MAX_SNAPSHOT_BYTES = 200 * 1024 * 1024;
export const MAX_ITEMS_PER_READ = 200;
/** Потолок суммарного размера шифротекста в одном ответе: иначе 200 пачек по 4 МБ съедят память. */
export const MAX_READ_CHARS = 8 * 1024 * 1024;
export const MAX_WAIT_SECONDS = 25;
const RECEIPT_RETENTION_MS = 14 * 24 * 3600_000;

export interface JournalItem {
  seq: number;
  batchId: string;
  deviceId: string;
  ciphertext: string;
}

export type ReadResult =
  | { kind: 'items'; items: JournalItem[]; hasMore: boolean }
  | { kind: 'compacted'; snapshotSeq: number };

export interface Journal {
  append(deviceId: string, batchId: string, ciphertext: string): { seq: number; created: boolean };
  /** Отдаёт пачки новее `after`; если их нет, ждёт новую до `waitSeconds`. */
  read(after: number, options: { waitSeconds: number; signal?: AbortSignal }): Promise<ReadResult>;
  ack(deviceId: string, seq: number): void;
  putSnapshot(deviceId: string, seq: number, ciphertext: string): void;
  getSnapshot(): { seq: number; ciphertext: string } | null;
  latestSnapshotSeq(): number | null;
  lastSeq(): number;
  /** Удаляет пачки ≤ снимка, если все активные устройства подтвердили этот номер. */
  compact(): void;
}

export class JournalRangeError extends Error {}

interface Row {
  seq: number;
  batch_id: string;
  device_id: string;
  ciphertext: string;
}

export function createJournal(db: Db, options: { devices: Devices; now?: () => number }): Journal {
  const { devices } = options;
  const now = options.now ?? Date.now;
  const waiters = new Set<() => void>();

  const findBatch = db.prepare('SELECT seq FROM batches WHERE batch_id = ?');
  const findReceipt = db.prepare('SELECT seq FROM batch_receipts WHERE batch_id = ?');
  const insertBatch = db.prepare('INSERT INTO batches (batch_id, device_id, ciphertext, created_at) VALUES (?, ?, ?, ?)');
  const selectAfter = db.prepare('SELECT seq, batch_id, device_id, ciphertext FROM batches WHERE seq > ? ORDER BY seq LIMIT ?');
  const sequence = db.prepare("SELECT seq FROM sqlite_sequence WHERE name = 'batches'");
  const getSnapshotRow = db.prepare('SELECT seq, ciphertext FROM snapshot WHERE id = 1');
  const getSnapshotSeq = db.prepare('SELECT seq FROM snapshot WHERE id = 1');
  const putSnapshotRow = db.prepare(
    `INSERT INTO snapshot (id, seq, ciphertext, created_at) VALUES (1, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET seq = excluded.seq, ciphertext = excluded.ciphertext, created_at = excluded.created_at`,
  );
  const getCompactedThrough = db.prepare("SELECT value FROM meta WHERE key = 'compacted_through'");
  const setCompactedThrough = db.prepare(
    "INSERT INTO meta (key, value) VALUES ('compacted_through', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
  );
  const moveToReceipts = db.prepare(
    'INSERT OR IGNORE INTO batch_receipts (batch_id, seq, created_at) SELECT batch_id, seq, created_at FROM batches WHERE seq <= ?',
  );
  const deleteCompacted = db.prepare('DELETE FROM batches WHERE seq <= ?');
  const dropOldReceipts = db.prepare('DELETE FROM batch_receipts WHERE created_at < ?');

  const lastSeq = () => (sequence.get() as { seq: number } | undefined)?.seq ?? 0;
  const snapshotSeq = () => (getSnapshotSeq.get() as { seq: number } | undefined)?.seq ?? null;
  const compactedThrough = () => (getCompactedThrough.get() as { value: number } | undefined)?.value ?? 0;

  function wakeWaiters(): void {
    for (const wake of [...waiters]) wake();
  }

  function readNow(after: number): ReadResult | null {
    if (after < compactedThrough()) return { kind: 'compacted', snapshotSeq: snapshotSeq() ?? compactedThrough() };
    const rows = selectAfter.all(after, MAX_ITEMS_PER_READ + 1) as Row[];
    if (rows.length === 0) return null;
    const items: JournalItem[] = [];
    let chars = 0;
    for (const row of rows.slice(0, MAX_ITEMS_PER_READ)) {
      if (items.length > 0 && chars + row.ciphertext.length > MAX_READ_CHARS) break;
      chars += row.ciphertext.length;
      items.push({ seq: row.seq, batchId: row.batch_id, deviceId: row.device_id, ciphertext: row.ciphertext });
    }
    return { kind: 'items', items, hasMore: items.length < rows.length };
  }

  function waitForWake(seconds: number, signal?: AbortSignal): Promise<void> {
    return new Promise((resolve) => {
      const finish = () => {
        clearTimeout(timer);
        waiters.delete(finish);
        signal?.removeEventListener('abort', finish);
        resolve();
      };
      const timer = setTimeout(finish, seconds * 1000);
      waiters.add(finish);
      signal?.addEventListener('abort', finish, { once: true });
    });
  }

  function compact(): void {
    const snapshot = snapshotSeq();
    if (snapshot === null || snapshot <= compactedThrough()) return;
    const minAck = devices.minActiveAck();
    if (minAck === null || minAck < snapshot) return;
    db.transaction(() => {
      moveToReceipts.run(snapshot);
      deleteCompacted.run(snapshot);
      setCompactedThrough.run(snapshot);
      dropOldReceipts.run(now() - RECEIPT_RETENTION_MS);
    })();
  }

  return {
    append(deviceId, batchId, ciphertext) {
      const existing = (findBatch.get(batchId) ?? findReceipt.get(batchId)) as { seq: number } | undefined;
      if (existing) return { seq: existing.seq, created: false };
      const seq = Number(insertBatch.run(batchId, deviceId, ciphertext, now()).lastInsertRowid);
      wakeWaiters();
      return { seq, created: true };
    },

    async read(after, { waitSeconds, signal }) {
      const immediate = readNow(after);
      if (immediate || waitSeconds <= 0) return immediate ?? { kind: 'items', items: [], hasMore: false };
      await waitForWake(Math.min(waitSeconds, MAX_WAIT_SECONDS), signal);
      return readNow(after) ?? { kind: 'items', items: [], hasMore: false };
    },

    ack(deviceId, seq) {
      if (seq > lastSeq()) throw new JournalRangeError('Номер больше последней пачки');
      devices.recordAck(deviceId, seq);
      compact();
    },

    putSnapshot(deviceId, seq, ciphertext) {
      if (seq > lastSeq()) throw new JournalRangeError('Номер снимка больше последней пачки');
      const current = snapshotSeq();
      if (current !== null && seq < current) throw new JournalRangeError('Снимок старее текущего');
      putSnapshotRow.run(seq, ciphertext, now());
      // тот, кто собрал снимок, уже применил всё до seq
      devices.recordAck(deviceId, seq);
      compact();
    },

    getSnapshot() {
      return (getSnapshotRow.get() as { seq: number; ciphertext: string } | undefined) ?? null;
    },

    latestSnapshotSeq: snapshotSeq,
    lastSeq,

    compact,
  };
}
