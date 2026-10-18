import { Hono, type Context } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { ApiError } from './errors.js';
import type { Devices } from './devices.js';
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

export function createApp({ devices, journal, limits = {} }: AppOptions): Hono<Env> {
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

  app.use('*', async (c, next) => {
    if (c.req.path === '/health' || c.req.path === '/devices/join') return next();
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

  return app;
}
