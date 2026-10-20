import { randomUUID } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readdirSync,
  renameSync,
  rmSync,
  rmdirSync,
  statSync,
  unlinkSync,
  createWriteStream,
} from 'node:fs';
import { join } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import type { Db } from './db.js';
import { ApiError } from './errors.js';

/** Часть исходника 8 МБ плюс nonce (12) и тег (16). */
export const PART_MAX_BYTES = 8_388_608 + 28;
/** Файл ≤ 100 МБ при частях по 8 МБ — не больше 13 частей. */
export const MAX_PARTS = 13;
export const TMP_DIR = '.tmp';

const DAY_MS = 24 * 3600_000;
const TRASH_KEEP_MS = 30 * DAY_MS;
const ABANDONED_KEEP_MS = 7 * DAY_MS;
const TMP_KEEP_MS = DAY_MS;

const FILE_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const PART_FILE = /^(\d+)\.part$/;

export interface FilesOptions {
  dir: string;
  limitBytes: number;
  now?: () => number;
}

export interface FileStatus {
  fileId: string;
  partCount: number;
  parts: number[];
  complete: boolean;
  bytes: number;
}

export interface FilesUsage {
  usedBytes: number;
  limitBytes: number;
  files: number;
}

export interface SweepResult {
  trashErased: number;
  abandonedErased: number;
}

export interface Files {
  /** Что уже лежит на сервере; `null` — файла нет или он в корзине. */
  status(fileId: string): FileStatus | null;
  putPart(fileId: string, index: number, count: number, body: ReadableStream<Uint8Array> | null): Promise<'created' | 'exists'>;
  complete(fileId: string, partCount: number): { bytes: number };
  /** Путь и размер собранной части для отдачи. */
  readPart(fileId: string, index: number): { path: string; size: number };
  /** В корзину на 30 дней; для неизвестного и уже удалённого файла — без ошибки. */
  remove(fileId: string): void;
  usage(): FilesUsage;
  /** Суточная уборка: корзина старше 30 дней, несобранные без новых частей 7 дней, старые временные файлы. */
  sweep(nowMs?: number): SweepResult;
}

interface FileRow {
  id: string;
  part_count: number;
  bytes: number;
  complete_at: number | null;
  deleted_at: number | null;
  created_at: number;
  updated_at: number;
}

const badRequest = (message: string, extra: Record<string, unknown> = {}) => new ApiError(400, 'bad_request', message, extra);

/** Приводит id к виду, безопасному для пути: UUID в нижнем регистре. */
export function normalizeFileId(raw: string): string {
  const id = raw.toLowerCase();
  if (!FILE_ID.test(id)) throw badRequest('Идентификатор файла должен быть UUID');
  return id;
}

export function createFiles(db: Db, { dir, limitBytes, now = Date.now }: FilesOptions): Files {
  const tmpDir = join(dir, TMP_DIR);
  const fileDir = (id: string) => join(dir, id.slice(0, 2), id);
  const partPath = (id: string, index: number) => join(fileDir(id), `${index}.part`);

  const selectRow = db.prepare('SELECT * FROM files WHERE id = ?');
  const insertRow = db.prepare(
    'INSERT INTO files (id, part_count, bytes, complete_at, deleted_at, created_at, updated_at) VALUES (?, ?, 0, NULL, NULL, ?, ?)',
  );
  const resetRow = db.prepare(
    'UPDATE files SET part_count = ?, bytes = 0, complete_at = NULL, deleted_at = NULL, created_at = ?, updated_at = ? WHERE id = ?',
  );
  const addPartBytes = db.prepare('UPDATE files SET bytes = bytes + ?, updated_at = ? WHERE id = ?');
  const markComplete = db.prepare('UPDATE files SET complete_at = ?, updated_at = ? WHERE id = ?');
  const markDeleted = db.prepare('UPDATE files SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL');
  const deleteRow = db.prepare('DELETE FROM files WHERE id = ?');
  const sumBytes = db.prepare('SELECT COALESCE(SUM(bytes), 0) AS total FROM files');
  const countLive = db.prepare('SELECT COUNT(*) AS total FROM files WHERE deleted_at IS NULL');
  const trashedBefore = db.prepare('SELECT id FROM files WHERE deleted_at IS NOT NULL AND deleted_at < ?');
  const abandonedBefore = db.prepare(
    'SELECT id FROM files WHERE complete_at IS NULL AND deleted_at IS NULL AND updated_at < ?',
  );

  const row = (id: string) => selectRow.get(id) as FileRow | undefined;
  const usedBytes = () => (sumBytes.get() as { total: number }).total;

  function storedParts(id: string): number[] {
    const folder = fileDir(id);
    if (!existsSync(folder)) return [];
    return readdirSync(folder)
      .map((name) => PART_FILE.exec(name)?.[1])
      .filter((index): index is string => index !== undefined)
      .map(Number)
      .sort((a, b) => a - b);
  }

  function eraseFolder(id: string): void {
    rmSync(fileDir(id), { recursive: true, force: true });
    try {
      rmdirSync(join(dir, id.slice(0, 2)));
    } catch {
      // в папке по первым знакам лежат другие файлы — оставляем
    }
  }

  function liveRow(id: string): FileRow | undefined {
    const found = row(id);
    return found && found.deleted_at === null ? found : undefined;
  }

  async function writeToTemp(body: ReadableStream<Uint8Array> | null, tmp: string): Promise<number> {
    if (!body) throw badRequest('Тело части не должно быть пустым');
    mkdirSync(tmpDir, { recursive: true });
    let size = 0;
    const counter = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        size += chunk.length;
        if (size > PART_MAX_BYTES) {
          callback(new ApiError(413, 'too_large', 'Часть больше 8 МБ'));
          return;
        }
        callback(null, chunk);
      },
    });
    await pipeline(Readable.fromWeb(body as import('node:stream/web').ReadableStream<Uint8Array>), counter, createWriteStream(tmp));
    if (size === 0) throw badRequest('Тело части не должно быть пустым');
    return size;
  }

  /** Всё, что можно проверить до чтения тела: дешёвый отказ без записи на диск. */
  function precheck(id: string, index: number, count: number): 'exists' | null {
    const found = liveRow(id);
    if (!found) return null;
    if (found.complete_at !== null) {
      throw new ApiError(409, 'file_complete', 'Файл уже собран и не меняется');
    }
    if (found.part_count !== count) throw badRequest('Число частей count не совпадает с прежним у этого файла');
    return existsSync(partPath(id, index)) ? 'exists' : null;
  }

  return {
    status(rawId) {
      const id = normalizeFileId(rawId);
      const found = liveRow(id);
      if (!found) return null;
      return {
        fileId: id,
        partCount: found.part_count,
        parts: storedParts(id),
        complete: found.complete_at !== null,
        bytes: found.bytes,
      };
    },

    async putPart(rawId, index, count, body) {
      const id = normalizeFileId(rawId);
      if (count < 1) throw badRequest('Параметр count должен быть не меньше 1');
      if (count > MAX_PARTS) throw new ApiError(413, 'too_large', 'Файл больше 100 МБ');
      if (index >= count) throw badRequest('Номер части должен быть меньше count');

      if (precheck(id, index, count) === 'exists') return 'exists';
      if (usedBytes() >= limitBytes) throw new ApiError(507, 'storage_full', 'На сервере кончилось место для файлов');

      const tmp = join(tmpDir, `${randomUUID()}.tmp`);
      try {
        const size = await writeToTemp(body, tmp);

        // дальше без await: между проверкой и переименованием другой запрос влезть не может
        const existing = row(id);
        const resurrect = existing !== undefined && existing.deleted_at !== null;
        if (existing && !resurrect) {
          if (precheck(id, index, count) === 'exists') return 'exists';
        }
        const used = usedBytes() - (resurrect ? existing.bytes : 0);
        if (used + size > limitBytes) throw new ApiError(507, 'storage_full', 'На сервере кончилось место для файлов');

        const stamp = now();
        if (!existing) insertRow.run(id, count, stamp, stamp);
        else if (resurrect) {
          eraseFolder(id);
          resetRow.run(count, stamp, stamp, id);
        }
        mkdirSync(fileDir(id), { recursive: true });
        renameSync(tmp, partPath(id, index));
        addPartBytes.run(size, stamp, id);
        return 'created';
      } finally {
        rmSync(tmp, { force: true });
      }
    },

    complete(rawId, partCount) {
      const id = normalizeFileId(rawId);
      const found = liveRow(id);
      if (!found) throw new ApiError(404, 'not_found', 'Такого файла на сервере нет');
      if (partCount !== found.part_count) throw badRequest('Число частей не совпадает с тем, что указано при отправке');
      if (found.complete_at !== null) return { bytes: found.bytes };
      const present = new Set(storedParts(id));
      const missing = Array.from({ length: partCount }, (_, index) => index).filter((index) => !present.has(index));
      if (missing.length > 0) throw badRequest('Не все части файла на месте', { missing });
      const stamp = now();
      markComplete.run(stamp, stamp, id);
      return { bytes: found.bytes };
    },

    readPart(rawId, index) {
      const id = normalizeFileId(rawId);
      const found = liveRow(id);
      if (!found) throw new ApiError(404, 'not_found', 'Такого файла на сервере нет');
      if (found.complete_at === null) {
        throw new ApiError(409, 'file_incomplete', 'Файл ещё не собран: отправитель не закончил');
      }
      const path = partPath(id, index);
      if (index >= found.part_count || !existsSync(path)) throw new ApiError(404, 'not_found', 'Такой части нет');
      return { path, size: statSync(path).size };
    },

    remove(rawId) {
      markDeleted.run(now(), normalizeFileId(rawId));
    },

    usage() {
      return {
        usedBytes: usedBytes(),
        limitBytes,
        files: (countLive.get() as { total: number }).total,
      };
    },

    sweep(nowMs = now()) {
      const erase = (ids: { id: string }[]) => {
        for (const { id } of ids) {
          eraseFolder(id);
          deleteRow.run(id);
        }
        return ids.length;
      };
      const trashErased = erase(trashedBefore.all(nowMs - TRASH_KEEP_MS) as { id: string }[]);
      const abandonedErased = erase(abandonedBefore.all(nowMs - ABANDONED_KEEP_MS) as { id: string }[]);

      if (existsSync(tmpDir)) {
        for (const name of readdirSync(tmpDir)) {
          const path = join(tmpDir, name);
          try {
            if (statSync(path).mtimeMs < nowMs - TMP_KEEP_MS) unlinkSync(path);
          } catch {
            // файл уже исчез: уборка не должна падать
          }
        }
      }
      return { trashErased, abandonedErased };
    },
  };
}
