import { createHash, randomBytes, randomUUID } from 'node:crypto';
import type { Db } from './db.js';

export const INVITE_LIFETIME_MS = 15 * 60_000;
const CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

export interface DeviceInfo {
  deviceId: string;
  deviceName: string;
  lastSeenAt: string | null;
  lastAckSeq: number;
}

export interface Devices {
  /** Первое устройство, когда в базе ещё никого нет. Токен возвращается один раз. */
  bootstrap(name: string): { deviceId: string; token: string };
  authenticate(token: string): { deviceId: string; deviceName: string } | null;
  createInvite(): { inviteCode: string; expiresAt: string };
  /** null — приглашение неизвестно, просрочено или уже использовано. */
  join(inviteCode: string, deviceName: string, initialAckSeq: number): { deviceId: string; deviceToken: string } | null;
  list(): DeviceInfo[];
  get(deviceId: string): DeviceInfo | null;
  disable(deviceId: string): 'disabled' | 'already' | 'unknown';
  recordAck(deviceId: string, seq: number): void;
  /** Наименьшее подтверждение среди активных устройств; null, если активных нет. */
  minActiveAck(): number | null;
}

interface DeviceRow {
  id: string;
  name: string;
  last_seen_at: number | null;
  last_ack_seq: number;
}

const toInfo = (row: DeviceRow): DeviceInfo => ({
  deviceId: row.id,
  deviceName: row.name,
  lastSeenAt: row.last_seen_at === null ? null : new Date(row.last_seen_at).toISOString(),
  lastAckSeq: row.last_ack_seq,
});

const sha256 = (value: string) => createHash('sha256').update(value).digest('hex');

function newInviteCode(): string {
  // 20 символов по 5 бит = 100 бит: вводится руками, не путает 0/O и 1/I
  const bytes = randomBytes(20);
  return Array.from(bytes, (byte) => CROCKFORD[byte % 32]).join('');
}

export function createDevices(db: Db, options: { now?: () => number } = {}): Devices {
  const now = options.now ?? Date.now;

  const insertDevice = db.prepare(
    'INSERT INTO devices (id, name, token_hash, created_at, last_ack_seq) VALUES (?, ?, ?, ?, ?)',
  );
  const countDevices = db.prepare('SELECT COUNT(*) AS n FROM devices');
  const findByHash = db.prepare('SELECT id, name FROM devices WHERE token_hash = ? AND disabled_at IS NULL');
  const touch = db.prepare('UPDATE devices SET last_seen_at = ? WHERE id = ?');
  const insertInvite = db.prepare('INSERT INTO invites (code_hash, created_at, expires_at) VALUES (?, ?, ?)');
  const useInvite = db.prepare(
    'UPDATE invites SET used_at = ? WHERE code_hash = ? AND used_at IS NULL AND expires_at > ?',
  );
  const dropOldInvites = db.prepare('DELETE FROM invites WHERE expires_at < ?');
  const listActive = db.prepare(
    'SELECT id, name, last_seen_at, last_ack_seq FROM devices WHERE disabled_at IS NULL ORDER BY created_at, id',
  );
  const findActiveById = db.prepare(
    'SELECT id, name, last_seen_at, last_ack_seq FROM devices WHERE id = ? AND disabled_at IS NULL',
  );
  const findById = db.prepare('SELECT disabled_at FROM devices WHERE id = ?');
  const disableById = db.prepare('UPDATE devices SET disabled_at = ? WHERE id = ?');
  const raiseAck = db.prepare('UPDATE devices SET last_ack_seq = MAX(last_ack_seq, ?) WHERE id = ?');
  const minAck = db.prepare('SELECT MIN(last_ack_seq) AS value FROM devices WHERE disabled_at IS NULL');

  function createDevice(name: string, initialAckSeq: number): { deviceId: string; token: string } {
    const deviceId = randomUUID();
    const token = randomBytes(32).toString('base64url');
    insertDevice.run(deviceId, name, sha256(token), now(), initialAckSeq);
    return { deviceId, token };
  }

  return {
    bootstrap(name) {
      if ((countDevices.get() as { n: number }).n > 0) throw new Error('Устройства уже есть');
      return createDevice(name, 0);
    },

    authenticate(token) {
      const row = findByHash.get(sha256(token)) as { id: string; name: string } | undefined;
      if (!row) return null;
      touch.run(now(), row.id);
      return { deviceId: row.id, deviceName: row.name };
    },

    createInvite() {
      const inviteCode = newInviteCode();
      const createdAt = now();
      const expiresAt = createdAt + INVITE_LIFETIME_MS;
      dropOldInvites.run(createdAt);
      insertInvite.run(sha256(inviteCode), createdAt, expiresAt);
      return { inviteCode, expiresAt: new Date(expiresAt).toISOString() };
    },

    join(inviteCode, deviceName, initialAckSeq) {
      const joinOnce = db.transaction(() => {
        if (useInvite.run(now(), sha256(inviteCode.trim()), now()).changes !== 1) return null;
        const { deviceId, token } = createDevice(deviceName, initialAckSeq);
        return { deviceId, deviceToken: token };
      });
      return joinOnce();
    },

    list() {
      return (listActive.all() as DeviceRow[]).map(toInfo);
    },

    get(deviceId) {
      const row = findActiveById.get(deviceId) as DeviceRow | undefined;
      return row ? toInfo(row) : null;
    },

    disable(deviceId) {
      const row = findById.get(deviceId) as { disabled_at: number | null } | undefined;
      if (!row) return 'unknown';
      if (row.disabled_at !== null) return 'already';
      disableById.run(now(), deviceId);
      return 'disabled';
    },

    recordAck(deviceId, seq) {
      raiseAck.run(seq, deviceId);
    },

    minActiveAck() {
      return (minAck.get() as { value: number | null }).value;
    },
  };
}
