import { randomBytes, randomUUID } from 'node:crypto';
import { createWriteStream, existsSync, mkdirSync, renameSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import type { Db } from './db.js';
import { ApiError } from './errors.js';
import { parseSharedDocument, UUID, type SharedDocument, type SharedFile } from './share-document.js';

/** Файл опубликованной страницы — не больше, чем MyNotion вообще хранит. */
export const MAX_SHARE_FILE_BYTES = 104_857_600;
const TOKEN = /^[A-Za-z0-9_-]{43}$/;

export interface Share {
  pageId: string;
  token: string;
  enabled: boolean;
  includeSubpages: boolean;
  digest: string | null;
  publishedAt: number | null;
}

/** Опубликованное по ссылке: снимок и файлы, которые сейчас есть на сервере. */
export interface PublishedShare {
  share: Share;
  document: SharedDocument;
  storedFiles: Set<string>;
}

export interface Shares {
  list(): Share[];
  /** Включить или выключить; первое включение создаёт ссылку, выключение стирает снимок и файлы. */
  setEnabled(pageId: string, enabled: boolean, includeSubpages?: boolean): Share;
  rotate(pageId: string): Share;
  remove(pageId: string): void;
  /** Новый снимок; возвращает id файлов снимка, которых ещё нет. */
  publish(pageId: string, digest: string, raw: unknown): string[];
  putFile(pageId: string, fileId: string, body: ReadableStream<Uint8Array> | null): Promise<'created' | 'exists'>;
  /** Открытая ссылка: `null` — нет такой, выключена или ещё без снимка. */
  open(token: string): PublishedShare | null;
  /** Путь файла открытой ссылки, если он есть в её снимке и уже загружен (того же размера, что в снимке). */
  filePath(published: PublishedShare, fileId: string): { path: string; file: SharedFile; size: number } | null;
}

interface Row {
  page_id: string;
  token: string;
  enabled: number;
  include_subpages: number;
  document: string | null;
  digest: string | null;
  published_at: number | null;
}

const notFound = () => new ApiError(404, 'not_found', 'Ссылки на эту страницу нет');
const badRequest = (message: string) => new ApiError(400, 'bad_request', message);

function checkPageId(pageId: string): string {
  const id = pageId.toLowerCase();
  if (!UUID.test(id)) throw badRequest('Идентификатор страницы должен быть UUID');
  return id;
}

const newToken = () => randomBytes(32).toString('base64url');

export function createShares(db: Db, options: { dir: string; limitBytes: number; now?: () => number }): Shares {
  const { dir, limitBytes } = options;
  const now = options.now ?? Date.now;
  const tmpDir = join(dir, '.tmp');
  const pageDir = (pageId: string) => join(dir, pageId);
  const filePath = (pageId: string, fileId: string) => join(pageDir(pageId), fileId);

  const selectAll = db.prepare('SELECT * FROM shares ORDER BY created_at, page_id');
  const selectByPage = db.prepare('SELECT * FROM shares WHERE page_id = ?');
  const selectByToken = db.prepare('SELECT * FROM shares WHERE token = ?');
  const insert = db.prepare(
    'INSERT INTO shares (page_id, token, enabled, include_subpages, created_at, updated_at) VALUES (?, ?, 1, ?, ?, ?)',
  );
  const update = db.prepare('UPDATE shares SET enabled = ?, include_subpages = ?, updated_at = ? WHERE page_id = ?');
  const clearDocument = db.prepare('UPDATE shares SET document = NULL, digest = NULL, published_at = NULL WHERE page_id = ?');
  const setToken = db.prepare('UPDATE shares SET token = ?, updated_at = ? WHERE page_id = ?');
  const setDocument = db.prepare('UPDATE shares SET document = ?, digest = ?, published_at = ?, updated_at = ? WHERE page_id = ?');
  const deleteShare = db.prepare('DELETE FROM shares WHERE page_id = ?');
  const filesOf = db.prepare('SELECT file_id, bytes FROM share_files WHERE page_id = ?');
  const insertFile = db.prepare('INSERT OR REPLACE INTO share_files (page_id, file_id, bytes, created_at) VALUES (?, ?, ?, ?)');
  const deleteFile = db.prepare('DELETE FROM share_files WHERE page_id = ? AND file_id = ?');
  const deleteFiles = db.prepare('DELETE FROM share_files WHERE page_id = ?');
  const fileBytes = db.prepare('SELECT COALESCE(SUM(bytes), 0) AS total FROM share_files');
  const documentBytes = db.prepare('SELECT COALESCE(SUM(LENGTH(CAST(document AS BLOB))), 0) AS total FROM shares');
  // место под файлы, которые ещё грузятся: проверка и бронь — одним синхронным шагом, параллельные загрузки лимит не обходят
  let reservedBytes = 0;
  const usedBytes = () =>
    (fileBytes.get() as { total: number }).total + (documentBytes.get() as { total: number }).total + reservedBytes;
  const storageFull = () => new ApiError(507, 'storage_full', 'На сервере кончилось место для опубликованных страниц');

  // недогруженные файлы прошлого запуска
  rmSync(tmpDir, { recursive: true, force: true });

  // Разобранный снимок — до смены digest: страница открывается без разбора JSON на каждый запрос.
  const parsed = new Map<string, { digest: string; document: SharedDocument }>();

  const toShare = (row: Row): Share => ({
    pageId: row.page_id,
    token: row.token,
    enabled: row.enabled === 1,
    includeSubpages: row.include_subpages === 1,
    digest: row.digest,
    publishedAt: row.published_at,
  });
  const rowOf = (pageId: string) => selectByPage.get(pageId) as Row | undefined;
  /** Загруженные файлы ссылки: id → размер. */
  const storedSizes = (pageId: string) =>
    new Map((filesOf.all(pageId) as { file_id: string; bytes: number }[]).map((row) => [row.file_id, row.bytes]));
  /** Файлы снимка, которые уже лежат на сервере в нужном размере. */
  const storedFiles = (pageId: string, document: SharedDocument) => {
    const sizes = storedSizes(pageId);
    return new Set([...document.files.values()].filter((file) => sizes.get(file.id) === file.byteCount).map((file) => file.id));
  };

  function eraseContent(pageId: string): void {
    db.transaction(() => {
      clearDocument.run(pageId);
      deleteFiles.run(pageId);
    })();
    parsed.delete(pageId);
    rmSync(pageDir(pageId), { recursive: true, force: true });
    // старые версии страниц базы лежат и в журнале WAL — переносим и обрезаем его
    db.pragma('wal_checkpoint(TRUNCATE)');
  }

  function documentOf(row: Row): SharedDocument | null {
    if (row.document === null || row.digest === null) return null;
    const cached = parsed.get(row.page_id);
    if (cached?.digest === row.digest) return cached.document;
    const document = parseSharedDocument(JSON.parse(row.document), row.page_id);
    parsed.set(row.page_id, { digest: row.digest, document });
    return document;
  }

  return {
    list: () => (selectAll.all() as Row[]).map(toShare),

    setEnabled(rawPageId, enabled, includeSubpages) {
      const pageId = checkPageId(rawPageId);
      const existing = rowOf(pageId);
      const stamp = now();
      if (!existing) {
        if (!enabled) throw notFound();
        insert.run(pageId, newToken(), includeSubpages === false ? 0 : 1, stamp, stamp);
      } else {
        const subpages = includeSubpages === undefined ? existing.include_subpages : includeSubpages ? 1 : 0;
        update.run(enabled ? 1 : 0, subpages, stamp, pageId);
        if (!enabled) eraseContent(pageId);
      }
      return toShare(rowOf(pageId)!);
    },

    rotate(rawPageId) {
      const pageId = checkPageId(rawPageId);
      if (!rowOf(pageId)) throw notFound();
      setToken.run(newToken(), now(), pageId);
      return toShare(rowOf(pageId)!);
    },

    remove(rawPageId) {
      const pageId = checkPageId(rawPageId);
      eraseContent(pageId);
      deleteShare.run(pageId);
    },

    publish(rawPageId, digest, raw) {
      const pageId = checkPageId(rawPageId);
      const row = rowOf(pageId);
      if (!row) throw notFound();
      if (row.enabled !== 1) throw new ApiError(409, 'share_disabled', 'Доступ по ссылке выключен — снимок не нужен');
      if (typeof digest !== 'string' || !/^[0-9a-f]{64}$/.test(digest)) throw badRequest('Поле digest должно быть SHA-256');
      const document = parseSharedDocument(raw, pageId);
      const json = JSON.stringify(raw);
      const previous = row.document === null ? 0 : Buffer.byteLength(row.document);
      if (usedBytes() - previous + Buffer.byteLength(json) > limitBytes) throw storageFull();
      const sizes = storedSizes(pageId);
      // убранный из снимка или сменивший размер файл стирается: новый догрузит приложение
      const stale = [...sizes].filter(([fileId, bytes]) => document.files.get(fileId)?.byteCount !== bytes).map(([fileId]) => fileId);
      const stamp = now();
      db.transaction(() => {
        setDocument.run(json, digest, stamp, stamp, pageId);
        for (const fileId of stale) deleteFile.run(pageId, fileId);
      })();
      for (const fileId of stale) rmSync(filePath(pageId, fileId), { force: true });
      parsed.set(pageId, { digest, document });
      const kept = new Set([...sizes.keys()].filter((fileId) => !stale.includes(fileId)));
      return [...document.files.keys()].filter((fileId) => !kept.has(fileId));
    },

    async putFile(rawPageId, rawFileId, body) {
      const pageId = checkPageId(rawPageId);
      const fileId = rawFileId.toLowerCase();
      if (!UUID.test(fileId)) throw badRequest('Идентификатор файла должен быть UUID');
      const row = rowOf(pageId);
      if (!row) throw notFound();
      const document = row.enabled === 1 ? documentOf(row) : null;
      const declared = document?.files.get(fileId);
      if (!declared) throw new ApiError(409, 'file_not_in_document', 'Этого файла нет в опубликованной странице');
      if (storedSizes(pageId).get(fileId) === declared.byteCount) return 'exists';
      if (declared.byteCount > MAX_SHARE_FILE_BYTES) throw new ApiError(413, 'too_large', 'Файл больше 100 МБ');
      if (usedBytes() + declared.byteCount > limitBytes) throw storageFull();
      if (!body) throw badRequest('Тело файла не должно быть пустым');
      reservedBytes += declared.byteCount;
      mkdirSync(tmpDir, { recursive: true });
      const tmp = join(tmpDir, `${randomUUID()}.tmp`);
      try {
        let size = 0;
        const counter = new Transform({
          transform(chunk: Buffer, _encoding, callback) {
            size += chunk.length;
            if (size > declared.byteCount) {
              callback(badRequest('Размер файла не совпадает со снимком'));
              return;
            }
            callback(null, chunk);
          },
        });
        await pipeline(Readable.fromWeb(body as import('node:stream/web').ReadableStream<Uint8Array>), counter, createWriteStream(tmp));
        if (size !== declared.byteCount) throw badRequest('Размер файла не совпадает со снимком');
        // за время загрузки ссылку могли выключить или убрать файл из снимка
        const current = rowOf(pageId);
        if (!current || current.enabled !== 1 || !documentOf(current)?.files.has(fileId)) {
          throw new ApiError(409, 'file_not_in_document', 'Этого файла нет в опубликованной странице');
        }
        mkdirSync(pageDir(pageId), { recursive: true });
        renameSync(tmp, filePath(pageId, fileId));
        insertFile.run(pageId, fileId, size, now());
        return 'created';
      } finally {
        reservedBytes -= declared.byteCount;
        rmSync(tmp, { force: true });
      }
    },

    open(token) {
      if (!TOKEN.test(token)) return null;
      const row = selectByToken.get(token) as Row | undefined;
      if (!row || row.enabled !== 1) return null;
      const document = documentOf(row);
      if (!document) return null;
      return { share: toShare(row), document, storedFiles: storedFiles(row.page_id, document) };
    },

    filePath(published, rawFileId) {
      const fileId = rawFileId.toLowerCase();
      const file = published.document.files.get(fileId);
      if (!file || !published.storedFiles.has(fileId)) return null;
      const path = filePath(published.share.pageId, fileId);
      if (!existsSync(path)) return null;
      return { path, file, size: statSync(path).size };
    },
  };
}
