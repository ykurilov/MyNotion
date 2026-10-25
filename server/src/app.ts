import { Hono, type Context } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { createReadStream } from 'node:fs';
import { Readable } from 'node:stream';
import { ApiError } from './errors.js';
import type { Devices } from './devices.js';
import { PART_MAX_BYTES, type Files } from './files.js';
import { MAX_DOCUMENT_BYTES } from './share-document.js';
import { renderNotFoundPage, renderSharedPage, STYLESHEET_PATH } from './share-render.js';
import { SHARE_STYLESHEET } from './share-style.js';
import { MAX_SHARE_FILE_BYTES, type Shares } from './shares.js';
import {
  JournalRangeError,
  MAX_BATCH_BYTES,
  MAX_SNAPSHOT_BYTES,
  MAX_WAIT_SECONDS,
  type Journal,
} from './journal.js';

export interface AppOptions {
  devices: Devices;
  journal: Journal;
  files: Files;
  shares?: Shares;
  limits?: { maxBatchBytes?: number; maxSnapshotBytes?: number };
}

type Env = { Variables: { deviceId: string } };

const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
const BATCH_ID = /^[A-Za-z0-9_-]{1,64}$/;
const DIGITS = /^\d{1,15}$/;
const MAX_DEVICE_NAME = 100;

const tooLarge = (what: string, megabytes: number) =>
  new ApiError(413, 'too_large', `${what} больше ${megabytes} МБ`);
const badRequest = (message: string) => new ApiError(400, 'bad_request', message);

function errorResponse(error: ApiError): Response {
  return Response.json({ error: error.code, message: error.message, ...error.extra }, { status: error.status });
}

async function readJson(c: Context): Promise<Record<string, unknown>> {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw badRequest('Тело запроса должно быть JSON');
  }
  if (typeof body !== 'object' || body === null || Array.isArray(body)) throw badRequest('Тело запроса должно быть объектом JSON');
  return body as Record<string, unknown>;
}

function readNonNegativeInt(value: unknown, field: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) {
    throw badRequest(`Поле ${field} должно быть целым числом от 0`);
  }
  return value;
}

function readPathNumber(value: string | undefined, what: string): number {
  if (value === undefined || !DIGITS.test(value)) throw badRequest(`${what} должен быть целым числом от 0`);
  return Number(value);
}

/** Проверяет base64 и считает размер до кодирования, не раскодируя сам шифротекст. */
function readCiphertext(value: unknown, maxBytes: number, what: string): string {
  if (typeof value !== 'string' || value.length === 0 || value.length % 4 !== 0 || !BASE64.test(value)) {
    throw badRequest('Поле ciphertext должно быть непустой строкой base64');
  }
  const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
  const decodedBytes = (value.length / 4) * 3 - padding;
  if (decodedBytes > maxBytes) throw tooLarge(what, Math.round(maxBytes / 1024 / 1024));
  return value;
}

function base64Chars(bytes: number): number {
  return Math.ceil(bytes / 3) * 4 + 4096;
}

export function createApp({ devices, journal, files, shares, limits = {} }: AppOptions): Hono<Env> {
  const maxBatchBytes = limits.maxBatchBytes ?? MAX_BATCH_BYTES;
  const maxSnapshotBytes = limits.maxSnapshotBytes ?? MAX_SNAPSHOT_BYTES;
  const app = new Hono<Env>();

  app.onError((error, c) => {
    if (error instanceof ApiError) return errorResponse(error);
    console.error('Необработанная ошибка:', error instanceof Error ? error.message : error);
    return errorResponse(new ApiError(500, 'server_error', 'Ошибка на сервере, попробуйте позже'));
  });
  app.notFound(() => errorResponse(new ApiError(404, 'not_found', 'Такого адреса нет')));

  const limitBody = (maxBytes: number, what: string) =>
    bodyLimit({
      maxSize: base64Chars(maxBytes) + 1024,
      onError: () => errorResponse(tooLarge(what, Math.round(maxBytes / 1024 / 1024))),
    });

  app.get('/health', (c) => c.json({ status: 'ok' }));

  app.post('/devices/join', async (c) => {
    const body = await readJson(c);
    const inviteCode = body.inviteCode;
    const deviceName = typeof body.deviceName === 'string' ? body.deviceName.trim() : '';
    if (typeof inviteCode !== 'string' || inviteCode.trim() === '') throw badRequest('Не указан код приглашения');
    if (deviceName === '' || deviceName.length > MAX_DEVICE_NAME) throw badRequest('Имя устройства должно быть от 1 до 100 символов');
    const joined = devices.join(inviteCode, deviceName, journal.latestSnapshotSeq() ?? 0);
    if (!joined) throw new ApiError(410, 'invite_expired', 'Приглашение просрочено или уже использовано');
    return c.json({ ...joined, latestSnapshotSeq: journal.latestSnapshotSeq() }, 201);
  });

  if (shares) mountPublicShares(app, shares);

  app.use('*', async (c, next) => {
    if (c.req.path === '/health' || c.req.path === '/devices/join' || isPublicSharePath(c.req.path)) return next();
    const header = c.req.header('authorization') ?? '';
    const token = /^Bearer (.+)$/i.exec(header)?.[1]?.trim();
    const device = token ? devices.authenticate(token) : null;
    if (!device) throw new ApiError(401, 'unauthorized', 'Нужен действующий токен устройства');
    c.set('deviceId', device.deviceId);
    return next();
  });

  app.post('/devices/invite', (c) => c.json(devices.createInvite(), 201));

  app.get('/devices', (c) => c.json(devices.list()));

  app.get('/devices/me', (c) => {
    const me = devices.get(c.get('deviceId'));
    if (!me) throw new ApiError(401, 'unauthorized', 'Нужен действующий токен устройства');
    return c.json(me);
  });

  app.delete('/devices/:deviceId', (c) => {
    const result = devices.disable(c.req.param('deviceId'));
    if (result === 'unknown') throw new ApiError(404, 'not_found', 'Такого устройства нет');
    if (result === 'disabled') journal.compact();
    return c.body(null, 204);
  });

  app.post('/changes', limitBody(maxBatchBytes, 'Пачка'), async (c) => {
    const body = await readJson(c);
    if (typeof body.batchId !== 'string' || !BATCH_ID.test(body.batchId)) throw badRequest('Поле batchId должно быть строкой до 64 символов');
    const ciphertext = readCiphertext(body.ciphertext, maxBatchBytes, 'Пачка');
    const { seq, created } = journal.append(c.get('deviceId'), body.batchId, ciphertext);
    return c.json({ seq }, created ? 201 : 200);
  });

  app.get('/changes', async (c) => {
    const afterParam = c.req.query('after') ?? '0';
    const waitParam = c.req.query('wait') ?? '0';
    if (!DIGITS.test(afterParam)) throw badRequest('Параметр after должен быть целым числом от 0');
    if (!DIGITS.test(waitParam)) throw badRequest(`Параметр wait должен быть целым числом от 0 до ${MAX_WAIT_SECONDS}`);
    const result = await journal.read(Number(afterParam), {
      waitSeconds: Math.min(Number(waitParam), MAX_WAIT_SECONDS),
      signal: c.req.raw.signal,
    });
    if (result.kind === 'compacted') {
      throw new ApiError(410, 'log_compacted', 'Журнал до этого номера уже сжат, сначала скачайте снимок', {
        snapshotSeq: result.snapshotSeq,
      });
    }
    return c.json({ items: result.items, hasMore: result.hasMore });
  });

  app.post('/ack', async (c) => {
    const body = await readJson(c);
    const seq = readNonNegativeInt(body.seq, 'seq');
    try {
      journal.ack(c.get('deviceId'), seq);
    } catch (error) {
      if (error instanceof JournalRangeError) throw badRequest(error.message);
      throw error;
    }
    return c.json({ ok: true });
  });

  app.put('/snapshot', limitBody(maxSnapshotBytes, 'Снимок'), async (c) => {
    const body = await readJson(c);
    const seq = readNonNegativeInt(body.seq, 'seq');
    const ciphertext = readCiphertext(body.ciphertext, maxSnapshotBytes, 'Снимок');
    try {
      journal.putSnapshot(c.get('deviceId'), seq, ciphertext);
    } catch (error) {
      if (error instanceof JournalRangeError) throw badRequest(error.message);
      throw error;
    }
    return c.json({ seq }, 201);
  });

  app.get('/snapshot', (c) => {
    const snapshot = journal.getSnapshot();
    if (!snapshot) throw new ApiError(404, 'not_found', 'Снимка пока нет');
    return c.json(snapshot);
  });

  app.get('/files/usage', (c) => c.json(files.usage()));

  app.get('/files/:fileId', (c) => {
    const status = files.status(c.req.param('fileId'));
    if (!status) throw new ApiError(404, 'not_found', 'Такого файла на сервере нет');
    return c.json(status);
  });

  app.put(
    '/files/:fileId/parts/:index',
    bodyLimit({ maxSize: PART_MAX_BYTES, onError: () => errorResponse(tooLarge('Часть файла', 8)) }),
    async (c) => {
      const index = readPathNumber(c.req.param('index'), 'Номер части');
      const count = readPathNumber(c.req.query('count'), 'Параметр count');
      const result = await files.putPart(c.req.param('fileId'), index, count, c.req.raw.body);
      return c.json({ index }, result === 'created' ? 201 : 200);
    },
  );

  app.post('/files/:fileId/complete', async (c) => {
    const body = await readJson(c);
    const partCount = readNonNegativeInt(body.partCount, 'partCount');
    return c.json(files.complete(c.req.param('fileId'), partCount));
  });

  app.get('/files/:fileId/parts/:index', (c) => {
    const index = readPathNumber(c.req.param('index'), 'Номер части');
    const { path, size } = files.readPart(c.req.param('fileId'), index);
    return new Response(Readable.toWeb(createReadStream(path)) as ReadableStream, {
      headers: { 'content-type': 'application/octet-stream', 'content-length': String(size) },
    });
  });

  app.delete('/files/:fileId', (c) => {
    files.remove(c.req.param('fileId'));
    return c.body(null, 204);
  });

  if (shares) mountShareControl(app, shares);

  return app;
}

// MARK: Страницы по ссылке

const isPublicSharePath = (path: string) =>
  path === '/robots.txt' || path === '/s' || path.startsWith('/s/') || path.startsWith('/share-assets/');

/** Общие заголовки открытой страницы: не индексировать, не передавать адрес дальше. */
const PUBLIC_HEADERS = {
  'x-robots-tag': 'noindex, nofollow',
  'referrer-policy': 'no-referrer',
  'x-content-type-options': 'nosniff',
} as const;
const PAGE_CSP =
  "default-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self'; media-src 'self'; script-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
/** Картинки и видео показываются на странице; всё остальное (и svg — в нём бывает скрипт) только скачивается. */
const INLINE_TYPES = new Set([
  'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif', 'image/heic', 'image/heif',
  'video/mp4', 'video/webm', 'video/quicktime',
]);

const htmlResponse = (html: string, status: number) =>
  new Response(html, {
    status,
    headers: { ...PUBLIC_HEADERS, 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store', 'content-security-policy': PAGE_CSP },
  });
const notFoundPage = () => htmlResponse(renderNotFoundPage(), 404);

function mountPublicShares(app: Hono<Env>, shares: Shares): void {
  app.get('/robots.txt', () =>
    new Response('User-agent: *\nDisallow: /\n', { headers: { ...PUBLIC_HEADERS, 'content-type': 'text/plain; charset=utf-8' } }),
  );

  app.get(STYLESHEET_PATH, () =>
    new Response(SHARE_STYLESHEET, {
      headers: { ...PUBLIC_HEADERS, 'content-type': 'text/css; charset=utf-8', 'cache-control': 'public, max-age=3600' },
    }),
  );

  const page = (token: string, pageId: string | undefined) => {
    const published = shares.open(token);
    if (!published) return notFoundPage();
    const id = pageId?.toLowerCase() ?? published.share.pageId;
    // без подстраниц снимок и так содержит одну страницу — лишнего не откроется
    const html = renderSharedPage(published.document, id, { token, availableFiles: published.storedFiles });
    return html === null ? notFoundPage() : htmlResponse(html, 200);
  };

  app.get('/s/:token', (c) => page(c.req.param('token'), undefined));
  app.get('/s/:token/:pageId', (c) => page(c.req.param('token'), c.req.param('pageId')));

  app.get('/s/:token/files/:fileId', (c) => {
    const published = shares.open(c.req.param('token'));
    const found = published ? shares.filePath(published, c.req.param('fileId')) : null;
    if (!found) return notFoundPage();
    const etag = `"${found.file.id}-${found.size}"`;
    const headers: Record<string, string> = {
      ...PUBLIC_HEADERS,
      'cache-control': 'private, no-cache',
      etag,
      'content-security-policy': "default-src 'none'; sandbox",
    };
    if (c.req.header('if-none-match') === etag) return new Response(null, { status: 304, headers });
    const inline = INLINE_TYPES.has(found.file.mimeType);
    const disposition = `${inline ? 'inline' : 'attachment'}; filename*=UTF-8''${encodeURIComponent(found.file.name)}`;
    return new Response(Readable.toWeb(createReadStream(found.path)) as ReadableStream, {
      headers: {
        ...headers,
        'content-type': inline ? found.file.mimeType : 'application/octet-stream',
        'content-length': String(found.size),
        'content-disposition': disposition,
      },
    });
  });

  app.all('/s/*', () => notFoundPage());
}

// MARK: Управление ссылками (с токеном устройства)

function mountShareControl(app: Hono<Env>, shares: Shares): void {
  app.get('/shares', (c) => c.json({ items: shares.list() }));

  app.put('/shares/:pageId', async (c) => {
    const body = await readJson(c);
    if (typeof body.enabled !== 'boolean') throw badRequest('Поле enabled должно быть true или false');
    if (body.includeSubpages !== undefined && typeof body.includeSubpages !== 'boolean') {
      throw badRequest('Поле includeSubpages должно быть true или false');
    }
    return c.json(shares.setEnabled(c.req.param('pageId'), body.enabled, body.includeSubpages as boolean | undefined));
  });

  app.post('/shares/:pageId/rotate', (c) => c.json(shares.rotate(c.req.param('pageId'))));

  app.delete('/shares/:pageId', (c) => {
    shares.remove(c.req.param('pageId'));
    return c.body(null, 204);
  });

  app.put(
    '/shares/:pageId/document',
    bodyLimit({ maxSize: MAX_DOCUMENT_BYTES + 4096, onError: () => errorResponse(tooLarge('Снимок страницы', 20)) }),
    async (c) => {
      const body = await readJson(c);
      const missingFiles = shares.publish(c.req.param('pageId'), body.digest as string, body.document);
      return c.json({ missingFiles });
    },
  );

  app.put(
    '/shares/:pageId/files/:fileId',
    bodyLimit({ maxSize: MAX_SHARE_FILE_BYTES, onError: () => errorResponse(tooLarge('Файл', 100)) }),
    async (c) => {
      const result = await shares.putFile(c.req.param('pageId'), c.req.param('fileId'), c.req.raw.body);
      return c.body(null, result === 'created' ? 201 : 200);
    },
  );
}
