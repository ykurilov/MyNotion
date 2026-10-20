import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { serve, type ServerType } from '@hono/node-server';
import type { AddressInfo } from 'node:net';
import { createHash } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import { PART_MAX_BYTES } from '../src/files.js';
import { createTestServer, expectRussianError, type TestServer } from './helpers.js';

const FILE = '11111111-2222-4333-8444-555555555555';
const OTHER = '99999999-2222-4333-8444-555555555555';
const DAY = 24 * 3600_000;

const part = (bytes: number, fill = 1) => Buffer.alloc(bytes, fill);

function put(server: TestServer, id: string, index: number, count: number, body: BodyInit = part(100), token?: string | null) {
  return server.call('PUT', `/files/${id}/parts/${index}?count=${count}`, { binary: body, token });
}

const complete = (server: TestServer, id: string, partCount: number) =>
  server.call('POST', `/files/${id}/complete`, { body: { partCount } });

async function uploadComplete(server: TestServer, id: string, sizes: number[]) {
  for (const [index, size] of sizes.entries()) {
    expect((await put(server, id, index, sizes.length, part(size, index + 1))).status).toBe(201);
  }
  expect((await complete(server, id, sizes.length)).status).toBe(200);
}

describe('части файла: загрузка', () => {
  it('новая часть — 201, повтор той же части — 200', async () => {
    const server = createTestServer();
    expect((await put(server, FILE, 0, 2)).status).toBe(201);
    expect((await put(server, FILE, 0, 2)).status).toBe(200);
  });

  it('повтор не меняет уже записанную часть и не двоит учёт', async () => {
    const server = createTestServer();
    await put(server, FILE, 0, 1, part(100, 5));
    await put(server, FILE, 0, 1, part(300, 9));
    const usage = (await (await server.call('GET', '/files/usage')).json()) as { usedBytes: number };
    expect(usage.usedBytes).toBe(100);
    await complete(server, FILE, 1);
    const body = Buffer.from(await (await server.call('GET', `/files/${FILE}/parts/0`)).arrayBuffer());
    expect(body.equals(part(100, 5))).toBe(true);
  });

  it('часть ровно «8 МБ + 28 байт» принимается, на байт больше — 413', async () => {
    const server = createTestServer();
    expect(PART_MAX_BYTES).toBe(8_388_608 + 28);
    expect((await put(server, FILE, 0, 2, part(PART_MAX_BYTES))).status).toBe(201);
    const response = await put(server, FILE, 1, 2, part(PART_MAX_BYTES + 1));
    expect(response.status).toBe(413);
    expectRussianError(await response.json(), 'too_large');
    expect((await (await server.call('GET', `/files/${FILE}`)).json()).parts).toEqual([0]);
  });

  it('часть без content-length (потоком) тоже ограничена', async () => {
    const server = createTestServer();
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(part(PART_MAX_BYTES));
        controller.enqueue(part(10));
        controller.close();
      },
    });
    const response = await server.app.request(`/files/${FILE}/parts/0?count=1`, {
      method: 'PUT',
      headers: { authorization: `Bearer ${server.firstDevice.token}`, 'transfer-encoding': 'chunked' },
      body: stream,
      duplex: 'half',
    } as RequestInit);
    expect(response.status).toBe(413);
  });

  it('пустое тело — 400', async () => {
    const server = createTestServer();
    const response = await put(server, FILE, 0, 1, part(0));
    expect(response.status).toBe(400);
    expectRussianError(await response.json(), 'bad_request');
  });

  it('count не совпадает у частей одного файла — 400', async () => {
    const server = createTestServer();
    await put(server, FILE, 0, 3);
    const response = await put(server, FILE, 1, 4);
    expect(response.status).toBe(400);
    expectRussianError(await response.json(), 'bad_request');
  });

  it.each([
    ['index ≥ count', `/files/${FILE}/parts/2?count=2`],
    ['count не указан', `/files/${FILE}/parts/0`],
    ['count = 0', `/files/${FILE}/parts/0?count=0`],
    ['count не число', `/files/${FILE}/parts/0?count=abc`],
    ['index не число', `/files/${FILE}/parts/x?count=2`],
    ['отрицательный index', `/files/${FILE}/parts/-1?count=2`],
    ['id не UUID', `/files/..%2Fevil/parts/0?count=1`],
  ])('неверные параметры (%s) — 400', async (_name, path) => {
    const server = createTestServer();
    const response = await server.call('PUT', path, { binary: part(10) });
    expect(response.status).toBe(400);
    expectRussianError(await response.json(), 'bad_request');
    expect(readdirSync(server.filesDir)).toEqual([]);
  });

  it('файл больше 100 МБ (больше 13 частей) — 413', async () => {
    const server = createTestServer();
    const response = await put(server, FILE, 0, 14);
    expect(response.status).toBe(413);
    expectRussianError(await response.json(), 'too_large');
  });

  it('после complete часть принять нельзя — 409 file_complete', async () => {
    const server = createTestServer();
    await uploadComplete(server, FILE, [50, 60]);
    for (const index of [0, 1]) {
      const response = await put(server, FILE, index, 2);
      expect(response.status).toBe(409);
      expectRussianError(await response.json(), 'file_complete');
    }
  });

  it('кончилась квота — 507 storage_full, ничего не остаётся на диске', async () => {
    const server = createTestServer(undefined, { limitBytes: 250 });
    expect((await put(server, FILE, 0, 3, part(100))).status).toBe(201);
    expect((await put(server, FILE, 1, 3, part(100))).status).toBe(201);
    const response = await put(server, FILE, 2, 3, part(100));
    expect(response.status).toBe(507);
    expectRussianError(await response.json(), 'storage_full');
    expect((await (await server.call('GET', `/files/${FILE}`)).json()).parts).toEqual([0, 1]);
    const dir = join(server.filesDir, FILE.slice(0, 2), FILE);
    expect(readdirSync(dir).sort()).toEqual(['0.part', '1.part']);
  });

  it('квота считается по всем файлам, место освобождается после стирания из корзины', async () => {
    const now = { value: Date.UTC(2026, 9, 19) };
    const server = createTestServer(undefined, { limitBytes: 250, now: () => now.value });
    await uploadComplete(server, FILE, [200]);
    expect((await put(server, OTHER, 0, 1, part(100))).status).toBe(507);
    await server.call('DELETE', `/files/${FILE}`);
    // в корзине файл ещё занимает место
    expect((await put(server, OTHER, 0, 1, part(100))).status).toBe(507);
    server.files.sweep(now.value + 31 * DAY);
    expect((await put(server, OTHER, 0, 1, part(100))).status).toBe(201);
  });

  it('оборванная запись части не оставляет ни части, ни временных файлов', async () => {
    const server = createTestServer();
    const broken = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(part(1000));
      },
      pull(controller) {
        controller.error(new Error('обрыв сети'));
      },
    });
    // content-length заявлен: Hono пропускает поток в обработчик, и обрыв случается посреди записи на диск
    const response = await server.call('PUT', `/files/${FILE}/parts/0?count=1`, {
      binary: broken,
      headers: { 'content-length': '5000' },
    });
    expect(response.status).toBeGreaterThanOrEqual(400);
    expect((await server.call('GET', `/files/${FILE}`)).status).toBe(404);
    const leftovers = readdirSync(server.filesDir, { recursive: true, withFileTypes: true }).filter((e) => e.isFile());
    expect(leftovers).toEqual([]);
    // файл можно отправить заново
    expect((await put(server, FILE, 0, 1)).status).toBe(201);
  });

  it('без токена — 401', async () => {
    const server = createTestServer();
    expect((await put(server, FILE, 0, 1, part(10), null)).status).toBe(401);
  });
});

describe('состояние файла и сборка', () => {
  it('GET /files/{id} — 404, пока ничего не отправлено', async () => {
    const server = createTestServer();
    const response = await server.call('GET', `/files/${FILE}`);
    expect(response.status).toBe(404);
    expectRussianError(await response.json(), 'not_found');
  });

  it('GET /files/{id} — список частей по порядку, число частей, размер, complete', async () => {
    const server = createTestServer();
    await put(server, FILE, 2, 3, part(30));
    await put(server, FILE, 0, 3, part(10));
    expect(await (await server.call('GET', `/files/${FILE}`)).json()).toEqual({
      fileId: FILE,
      partCount: 3,
      parts: [0, 2],
      complete: false,
      bytes: 40,
    });
  });

  it('id в верхнем регистре — тот же файл', async () => {
    const server = createTestServer();
    await put(server, FILE.toUpperCase(), 0, 1);
    expect((await server.call('GET', `/files/${FILE}`)).status).toBe(200);
  });

  it('complete: все части на месте — 200 с размером; повтор — тоже 200', async () => {
    const server = createTestServer();
    await put(server, FILE, 0, 2, part(10));
    await put(server, FILE, 1, 2, part(5));
    const first = await complete(server, FILE, 2);
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({ bytes: 15 });
    expect((await complete(server, FILE, 2)).status).toBe(200);
    expect(await (await server.call('GET', `/files/${FILE}`)).json()).toMatchObject({ complete: true, bytes: 15 });
  });

  it('complete: не хватает частей — 400 со списком missing, файл остаётся несобранным', async () => {
    const server = createTestServer();
    await put(server, FILE, 1, 4);
    const response = await complete(server, FILE, 4);
    expect(response.status).toBe(400);
    const body = (await response.json()) as { missing: number[] };
    expectRussianError(body, 'bad_request');
    expect(body.missing).toEqual([0, 2, 3]);
    expect(await (await server.call('GET', `/files/${FILE}`)).json()).toMatchObject({ complete: false });
  });

  it('complete: partCount не совпадает с count частей — 400; файла нет — 404; кривое тело — 400', async () => {
    const server = createTestServer();
    expect((await complete(server, FILE, 2)).status).toBe(404);
    await put(server, FILE, 0, 2);
    expect((await complete(server, FILE, 3)).status).toBe(400);
    expect((await server.call('POST', `/files/${FILE}/complete`, { body: { partCount: 'два' } })).status).toBe(400);
    expect((await server.call('POST', `/files/${FILE}/complete`, { rawBody: '{' })).status).toBe(400);
  });

  it('GET части до сборки — 409 file_incomplete', async () => {
    const server = createTestServer();
    await put(server, FILE, 0, 2);
    const response = await server.call('GET', `/files/${FILE}/parts/0`);
    expect(response.status).toBe(409);
    expectRussianError(await response.json(), 'file_incomplete');
  });

  it('GET части после сборки отдаёт байты как есть; нет части или файла — 404', async () => {
    const server = createTestServer();
    await uploadComplete(server, FILE, [40, 20]);
    const first = await server.call('GET', `/files/${FILE}/parts/0`);
    expect(first.status).toBe(200);
    expect(first.headers.get('content-type')).toBe('application/octet-stream');
    expect(Buffer.from(await first.arrayBuffer()).equals(part(40, 1))).toBe(true);
    const second = await server.call('GET', `/files/${FILE}/parts/1`);
    expect(Buffer.from(await second.arrayBuffer()).equals(part(20, 2))).toBe(true);
    expect((await server.call('GET', `/files/${FILE}/parts/2`)).status).toBe(404);
    expect((await server.call('GET', `/files/${OTHER}/parts/0`)).status).toBe(404);
  });

  it('без токена — 401 на всех адресах', async () => {
    const server = createTestServer();
    for (const [method, path] of [
      ['GET', `/files/${FILE}`],
      ['POST', `/files/${FILE}/complete`],
      ['GET', `/files/${FILE}/parts/0`],
      ['DELETE', `/files/${FILE}`],
      ['GET', '/files/usage'],
    ] as const) {
      expect((await server.call(method, path, { token: null })).status).toBe(401);
    }
  });
});

describe('удаление и корзина сервера', () => {
  it('DELETE — 204, повтор — 204, даже для неизвестного файла; затем GET — 404', async () => {
    const server = createTestServer();
    await uploadComplete(server, FILE, [30]);
    expect((await server.call('DELETE', `/files/${FILE}`)).status).toBe(204);
    expect((await server.call('DELETE', `/files/${FILE}`)).status).toBe(204);
    expect((await server.call('DELETE', `/files/${OTHER}`)).status).toBe(204);
    expect((await server.call('GET', `/files/${FILE}`)).status).toBe(404);
    expect((await server.call('GET', `/files/${FILE}/parts/0`)).status).toBe(404);
    expect((await complete(server, FILE, 1)).status).toBe(404);
  });

  it('отправка части в файл из корзины достаёт его и стирает прежние части', async () => {
    const server = createTestServer();
    await uploadComplete(server, FILE, [30, 30, 30]);
    await server.call('DELETE', `/files/${FILE}`);

    expect((await put(server, FILE, 0, 2, part(7, 9))).status).toBe(201);
    expect(await (await server.call('GET', `/files/${FILE}`)).json()).toEqual({
      fileId: FILE,
      partCount: 2,
      parts: [0],
      complete: false,
      bytes: 7,
    });
    expect(readdirSync(join(server.filesDir, FILE.slice(0, 2), FILE))).toEqual(['0.part']);

    await put(server, FILE, 1, 2, part(8, 9));
    expect(await (await complete(server, FILE, 2)).json()).toEqual({ bytes: 15 });
  });

  it('удалённый файл не показывается в usage, но занимает квоту до стирания', async () => {
    const server = createTestServer();
    await uploadComplete(server, FILE, [30]);
    await uploadComplete(server, OTHER, [20]);
    await server.call('DELETE', `/files/${FILE}`);
    expect(await (await server.call('GET', '/files/usage')).json()).toMatchObject({ files: 1, usedBytes: 50 });
  });
});

describe('GET /files/usage', () => {
  it('пустое хранилище', async () => {
    const server = createTestServer(undefined, { limitBytes: 1000 });
    expect(await (await server.call('GET', '/files/usage')).json()).toEqual({ usedBytes: 0, limitBytes: 1000, files: 0 });
  });

  it('считает размер и число файлов, включая несобранные', async () => {
    const server = createTestServer(undefined, { limitBytes: 1000 });
    await uploadComplete(server, FILE, [30, 20]);
    await put(server, OTHER, 0, 2, part(5));
    expect(await (await server.call('GET', '/files/usage')).json()).toEqual({ usedBytes: 55, limitBytes: 1000, files: 2 });
  });
});

describe('суточная уборка', () => {
  const start = Date.UTC(2026, 9, 1);

  it('корзина старше 30 дней стирается вместе с частями, моложе — нет', async () => {
    const now = { value: start };
    const server = createTestServer(undefined, { now: () => now.value });
    await uploadComplete(server, FILE, [30]);
    await uploadComplete(server, OTHER, [30]);
    await server.call('DELETE', `/files/${FILE}`);
    now.value += 10 * DAY;
    await server.call('DELETE', `/files/${OTHER}`);

    now.value = start + 31 * DAY;
    expect(server.files.sweep(now.value)).toEqual({ trashErased: 1, abandonedErased: 0 });
    expect(existsSync(join(server.filesDir, FILE.slice(0, 2), FILE))).toBe(false);
    expect(existsSync(join(server.filesDir, OTHER.slice(0, 2), OTHER, '0.part'))).toBe(true);

    now.value = start + 41 * DAY;
    expect(server.files.sweep(now.value)).toEqual({ trashErased: 1, abandonedErased: 0 });
    expect(await (await server.call('GET', '/files/usage')).json()).toMatchObject({ usedBytes: 0, files: 0 });
  });

  it('несобранный файл без новых частей 7 дней стирается; свежая часть продлевает жизнь', async () => {
    const now = { value: start };
    const server = createTestServer(undefined, { now: () => now.value });
    await put(server, FILE, 0, 2);
    await put(server, OTHER, 0, 2);
    now.value = start + 5 * DAY;
    await put(server, OTHER, 1, 2); // новая часть

    now.value = start + 8 * DAY;
    expect(server.files.sweep(now.value)).toEqual({ trashErased: 0, abandonedErased: 1 });
    expect((await server.call('GET', `/files/${FILE}`)).status).toBe(404);
    expect((await server.call('GET', `/files/${OTHER}`)).status).toBe(200);
    expect(existsSync(join(server.filesDir, FILE.slice(0, 2), FILE))).toBe(false);
  });

  it('собранный файл без обращений не стирается никогда', async () => {
    const now = { value: start };
    const server = createTestServer(undefined, { now: () => now.value });
    await uploadComplete(server, FILE, [30]);
    now.value = start + 400 * DAY;
    expect(server.files.sweep(now.value)).toEqual({ trashErased: 0, abandonedErased: 0 });
    expect((await server.call('GET', `/files/${FILE}`)).status).toBe(200);
  });

  it('старые временные файлы записи стираются', async () => {
    const now = { value: start };
    const server = createTestServer(undefined, { now: () => now.value });
    const { writeFileSync, utimesSync, mkdirSync } = await import('node:fs');
    const tmpDir = join(server.filesDir, '.tmp');
    mkdirSync(tmpDir, { recursive: true });
    const stale = join(tmpDir, 'old.tmp');
    writeFileSync(stale, 'x');
    utimesSync(stale, new Date(start - 2 * DAY), new Date(start - 2 * DAY));
    server.files.sweep(start);
    expect(existsSync(stale)).toBe(false);
  });
});

describe('живой случай: настоящий HTTP, часть в 8 МБ', () => {
  let http: ServerType;
  let baseUrl: string;
  let token: string;
  let server: TestServer;

  beforeEach(async () => {
    server = createTestServer();
    token = server.firstDevice.token;
    http = serve({ fetch: createApp({ devices: server.devices, journal: server.journal, files: server.files }).fetch, port: 0, hostname: '127.0.0.1' });
    await new Promise<void>((resolve) => http.once('listening', () => resolve()));
    baseUrl = `http://127.0.0.1:${(http.address() as AddressInfo).port}`;
  });
  afterEach(() => new Promise<void>((resolve) => http.close(() => resolve())));

  it('полная часть уходит на сервер и возвращается байт в байт', async () => {
    const original = Buffer.alloc(PART_MAX_BYTES);
    for (let i = 0; i < original.length; i += 1) original[i] = (i * 31 + 7) & 255;
    const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/octet-stream' };

    const sent = await fetch(`${baseUrl}/files/${FILE}/parts/0?count=1`, { method: 'PUT', headers, body: original });
    expect(sent.status).toBe(201);
    expect((await fetch(`${baseUrl}/files/${FILE}/complete`, { method: 'POST', headers: { authorization: headers.authorization }, body: JSON.stringify({ partCount: 1 }) })).status).toBe(200);

    const got = await fetch(`${baseUrl}/files/${FILE}/parts/0`, { headers: { authorization: headers.authorization } });
    expect(got.headers.get('content-length')).toBe(String(PART_MAX_BYTES));
    const back = Buffer.from(await got.arrayBuffer());
    expect(createHash('sha256').update(back).digest('hex')).toBe(createHash('sha256').update(original).digest('hex'));
  });

  it('часть больше предела по content-length отвергается 413 до записи', async () => {
    const response = await fetch(`${baseUrl}/files/${FILE}/parts/0?count=1`, {
      method: 'PUT',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/octet-stream' },
      body: Buffer.alloc(PART_MAX_BYTES + 1),
    });
    expect(response.status).toBe(413);
    expect((await fetch(`${baseUrl}/files/${FILE}`, { headers: { authorization: `Bearer ${token}` } })).status).toBe(404);
  });
});
