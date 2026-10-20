import { serve, type ServerType } from '@hono/node-server';
import type { AddressInfo } from 'node:net';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createApp } from '../src/app.js';
import { MAX_BATCH_BYTES, MAX_SNAPSHOT_BYTES } from '../src/journal.js';
import { ciphertextOf, createTestServer, expectRussianError, joinDevice, type TestServer } from './helpers.js';

interface ChangesBody {
  items: Array<{ seq: number; batchId: string; deviceId: string; ciphertext: string }>;
  hasMore: boolean;
}

const post = (server: TestServer, batchId: string, ciphertext = 'AAAA', token?: string) =>
  server.call('POST', '/changes', { token, body: { batchId, ciphertext } });
const read = async (server: TestServer, query: string, token?: string) => {
  const response = await server.call('GET', `/changes${query}`, { token });
  return { response, body: (await response.json()) as ChangesBody };
};

describe('журнал пачек', () => {
  let server: TestServer;
  beforeEach(() => {
    server = createTestServer();
  });

  it('лимиты соответствуют контракту', () => {
    expect(MAX_BATCH_BYTES).toBe(4 * 1024 * 1024);
    expect(MAX_SNAPSHOT_BYTES).toBe(200 * 1024 * 1024);
  });

  it('POST /changes: 201 и номера по порядку', async () => {
    const first = await post(server, 'b-1');
    expect(first.status).toBe(201);
    expect(await first.json()).toEqual({ seq: 1 });
    const second = await post(server, 'b-2');
    expect(await second.json()).toEqual({ seq: 2 });
  });

  it('повтор того же batchId — 200 с прежним seq, дубля нет', async () => {
    await post(server, 'b-1', 'AAAA');
    const repeat = await post(server, 'b-1', 'AAAA');
    expect(repeat.status).toBe(200);
    expect(await repeat.json()).toEqual({ seq: 1 });
    const { body } = await read(server, '?after=0');
    expect(body.items).toHaveLength(1);
  });

  it('пачка ровно 4 МБ принимается, на байт больше — too_large', async () => {
    const exact = await post(server, 'b-big', ciphertextOf(MAX_BATCH_BYTES));
    expect(exact.status).toBe(201);
    const over = await post(server, 'b-bigger', ciphertextOf(MAX_BATCH_BYTES + 1));
    expect(over.status).toBe(413);
    expectRussianError(await over.json(), 'too_large');
  });

  it('кривое тело — 400', async () => {
    for (const body of [{}, { batchId: 'x' }, { batchId: '', ciphertext: 'AAAA' }, { batchId: 'x', ciphertext: 'не base64!' }]) {
      const response = await server.call('POST', '/changes', { body });
      expect(response.status).toBe(400);
      expectRussianError(await response.json(), 'bad_request');
    }
  });

  it('без токена — 401', async () => {
    expect((await server.call('POST', '/changes', { token: null, body: { batchId: 'x', ciphertext: 'AAAA' } })).status).toBe(401);
    expect((await server.call('GET', '/changes?after=0', { token: null })).status).toBe(401);
  });

  it('GET /changes: отдаёт пачки новее after с полями из контракта', async () => {
    const second = await joinDevice(server, 'Второй Mac');
    await post(server, 'b-1', 'AAAA');
    await post(server, 'b-2', 'BBBB', second.token);
    await post(server, 'b-3', 'CCCC');

    const { response, body } = await read(server, '?after=1');
    expect(response.status).toBe(200);
    expect(body.hasMore).toBe(false);
    expect(body.items).toEqual([
      { seq: 2, batchId: 'b-2', deviceId: second.deviceId, ciphertext: 'BBBB' },
      { seq: 3, batchId: 'b-3', deviceId: server.firstDevice.deviceId, ciphertext: 'CCCC' },
    ]);
  });

  it('GET /changes: не больше 200 пачек за раз и hasMore', async () => {
    for (let i = 1; i <= 205; i++) server.journal.append(server.firstDevice.deviceId, `b-${i}`, 'AAAA');
    const firstPage = await read(server, '?after=0');
    expect(firstPage.body.items).toHaveLength(200);
    expect(firstPage.body.hasMore).toBe(true);
    const rest = await read(server, `?after=${firstPage.body.items.at(-1)!.seq}`);
    expect(rest.body.items.map((item) => item.seq)).toEqual([201, 202, 203, 204, 205]);
    expect(rest.body.hasMore).toBe(false);
  });

  it('GET /changes: ответ ограничен по объёму, но пачки не теряются', async () => {
    const big = ciphertextOf(3 * 1024 * 1024);
    for (let i = 1; i <= 3; i++) server.journal.append(server.firstDevice.deviceId, `big-${i}`, big);
    const firstPage = await read(server, '?after=0');
    expect(firstPage.body.items.length).toBeGreaterThanOrEqual(1);
    expect(firstPage.body.items.length).toBeLessThan(3);
    expect(firstPage.body.hasMore).toBe(true);
    const rest = await read(server, `?after=${firstPage.body.items.at(-1)!.seq}`);
    expect(firstPage.body.items.length + rest.body.items.length).toBe(3);
  });

  it('GET /changes: неверные параметры — 400, большой wait обрезается до 25', async () => {
    for (const query of ['?after=-1', '?after=abc', '?after=0&wait=-3', '?after=0&wait=x']) {
      const response = await server.call('GET', `/changes${query}`);
      expect(response.status).toBe(400);
      expectRussianError(await response.json(), 'bad_request');
    }
    const clamped = await read(server, '?after=0&wait=0');
    expect(clamped.response.status).toBe(200);
  });

  describe('долгое ожидание (подменённые часы)', () => {
    beforeEach(() => vi.useFakeTimers());
    afterEach(() => vi.useRealTimers());

    it('без новостей отвечает пусто только через 25 секунд', async () => {
      let answered = false;
      const pending = server.call('GET', '/changes?after=0&wait=25').then((response) => {
        answered = true;
        return response;
      });
      await vi.advanceTimersByTimeAsync(24_900);
      expect(answered).toBe(false);
      await vi.advanceTimersByTimeAsync(200);
      const response = await pending;
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ items: [], hasMore: false });
    });

    it('wait больше 25 обрезается до 25', async () => {
      const pending = server.call('GET', '/changes?after=0&wait=300');
      await vi.advanceTimersByTimeAsync(25_100);
      expect(await (await pending).json()).toEqual({ items: [], hasMore: false });
    });

    it('новая пачка будит ожидание сразу, время не двигалось', async () => {
      const second = await joinDevice(server, 'Второй Mac');
      const pending = server.call('GET', '/changes?after=0&wait=25');
      await vi.advanceTimersByTimeAsync(1_000);
      await post(server, 'fresh', 'DDDD', second.token);
      const response = await pending;
      const body = (await response.json()) as ChangesBody;
      expect(body.items.map((item) => item.batchId)).toEqual(['fresh']);
      expect(vi.getTimerCount()).toBe(0);
    });

    it('если пачка уже есть, отвечает сразу, не ожидая', async () => {
      await post(server, 'ready');
      const response = await server.call('GET', '/changes?after=0&wait=25');
      expect(((await response.json()) as ChangesBody).items).toHaveLength(1);
      expect(vi.getTimerCount()).toBe(0);
    });
  });

  describe('снимки и сжатие', () => {
    it('GET /snapshot: 404, пока снимка нет', async () => {
      const response = await server.call('GET', '/snapshot');
      expect(response.status).toBe(404);
      expectRussianError(await response.json(), 'not_found');
    });

    it('PUT/GET /snapshot: 201 и тот же шифротекст', async () => {
      await post(server, 'b-1');
      await post(server, 'b-2');
      const put = await server.call('PUT', '/snapshot', { body: { seq: 2, ciphertext: 'U05BUFNIT1Q=' } });
      expect(put.status).toBe(201);
      const got = await server.call('GET', '/snapshot');
      expect(await got.json()).toEqual({ seq: 2, ciphertext: 'U05BUFNIT1Q=' });
    });

    it('снимок с seq из будущего или старее текущего — 400', async () => {
      await post(server, 'b-1');
      await post(server, 'b-2');
      const future = await server.call('PUT', '/snapshot', { body: { seq: 9, ciphertext: 'AAAA' } });
      expect(future.status).toBe(400);
      await server.call('PUT', '/snapshot', { body: { seq: 2, ciphertext: 'AAAA' } });
      const older = await server.call('PUT', '/snapshot', { body: { seq: 1, ciphertext: 'AAAA' } });
      expect(older.status).toBe(400);
    });

    it('слишком большой снимок — too_large', async () => {
      const small = createTestServer({ maxSnapshotBytes: 1024 });
      small.journal.append(small.firstDevice.deviceId, 'b-1', 'AAAA');
      const response = await small.call('PUT', '/snapshot', { body: { seq: 1, ciphertext: ciphertextOf(1025) } });
      expect(response.status).toBe(413);
      expectRussianError(await response.json(), 'too_large');
      const fits = await small.call('PUT', '/snapshot', { body: { seq: 1, ciphertext: ciphertextOf(1024) } });
      expect(fits.status).toBe(201);
    });

    it('пачки ≤ seq удаляются, только когда все активные устройства подтвердили', async () => {
      const second = await joinDevice(server, 'Второй Mac');
      for (const id of ['b-1', 'b-2', 'b-3']) await post(server, id);

      await server.call('PUT', '/snapshot', { body: { seq: 2, ciphertext: 'AAAA' } });
      expect(server.db.prepare('SELECT COUNT(*) AS n FROM batches').get()).toEqual({ n: 3 });

      const ack = await server.call('POST', '/ack', { token: second.token, body: { seq: 2 } });
      expect(ack.status).toBe(200);
      expect(server.db.prepare('SELECT COUNT(*) AS n FROM batches').get()).toEqual({ n: 1 });

      const stale = await server.call('GET', '/changes?after=1');
      expect(stale.status).toBe(410);
      const staleBody = (await stale.json()) as { snapshotSeq: number };
      expect(staleBody.snapshotSeq).toBe(2);
      expectRussianError(staleBody, 'log_compacted');

      const upToDate = await read(server, '?after=2');
      expect(upToDate.body.items.map((item) => item.seq)).toEqual([3]);
    });

    it('подтверждение меньше seq снимка ничего не удаляет', async () => {
      const second = await joinDevice(server, 'Второй Mac');
      for (const id of ['b-1', 'b-2', 'b-3']) await post(server, id);
      await server.call('PUT', '/snapshot', { body: { seq: 3, ciphertext: 'AAAA' } });
      await server.call('POST', '/ack', { token: second.token, body: { seq: 2 } });
      expect(server.db.prepare('SELECT COUNT(*) AS n FROM batches').get()).toEqual({ n: 3 });
      await server.call('POST', '/ack', { token: second.token, body: { seq: 3 } });
      expect(server.db.prepare('SELECT COUNT(*) AS n FROM batches').get()).toEqual({ n: 0 });
    });

    it('отключённое отстающее устройство больше не держит журнал', async () => {
      const lost = await joinDevice(server, 'Потерянный Mac');
      for (const id of ['b-1', 'b-2']) await post(server, id);
      await server.call('PUT', '/snapshot', { body: { seq: 2, ciphertext: 'AAAA' } });
      expect(server.db.prepare('SELECT COUNT(*) AS n FROM batches').get()).toEqual({ n: 2 });
      await server.call('DELETE', `/devices/${lost.deviceId}`);
      expect(server.db.prepare('SELECT COUNT(*) AS n FROM batches').get()).toEqual({ n: 0 });
    });

    it('номера не повторяются после полного сжатия, а повтор batchId всё ещё узнаётся', async () => {
      await post(server, 'b-1');
      await post(server, 'b-2');
      await server.call('PUT', '/snapshot', { body: { seq: 2, ciphertext: 'AAAA' } });
      expect(server.db.prepare('SELECT COUNT(*) AS n FROM batches').get()).toEqual({ n: 0 });

      const next = await post(server, 'b-3');
      expect(await next.json()).toEqual({ seq: 3 });

      const repeat = await post(server, 'b-1');
      expect(repeat.status).toBe(200);
      expect(await repeat.json()).toEqual({ seq: 1 });
    });

    it('новое устройство после снимка получает его seq и считается подтвердившим его', async () => {
      await post(server, 'b-1');
      await server.call('PUT', '/snapshot', { body: { seq: 1, ciphertext: 'AAAA' } });
      const invite = (await (await server.call('POST', '/devices/invite')).json()) as { inviteCode: string };
      const joined = (await (
        await server.call('POST', '/devices/join', { token: null, body: { inviteCode: invite.inviteCode, deviceName: 'Новый' } })
      ).json()) as { latestSnapshotSeq: number; deviceId: string };
      expect(joined.latestSnapshotSeq).toBe(1);
      const list = (await (await server.call('GET', '/devices')).json()) as Array<{ deviceId: string; lastAckSeq: number }>;
      expect(list.find((device) => device.deviceId === joined.deviceId)!.lastAckSeq).toBe(1);
    });
  });

  describe('/ack', () => {
    it('запоминает подтверждение и не откатывается назад', async () => {
      await post(server, 'b-1');
      await post(server, 'b-2');
      const ack = await server.call('POST', '/ack', { body: { seq: 2 } });
      expect(ack.status).toBe(200);
      await server.call('POST', '/ack', { body: { seq: 1 } });
      const list = (await (await server.call('GET', '/devices')).json()) as Array<{ lastAckSeq: number }>;
      expect(list[0]!.lastAckSeq).toBe(2);
    });

    it('подтверждение несуществующего seq или кривого значения — 400', async () => {
      await post(server, 'b-1');
      for (const body of [{ seq: 5 }, { seq: -1 }, { seq: 'x' }, {}]) {
        const response = await server.call('POST', '/ack', { body });
        expect(response.status).toBe(400);
        expectRussianError(await response.json(), 'bad_request');
      }
    });
  });
});

describe('живой случай: настоящий HTTP и настоящее время', () => {
  let http: ServerType;
  let baseUrl: string;
  let token: string;

  beforeEach(async () => {
    const server = createTestServer();
    token = server.firstDevice.token;
    const app = createApp({ devices: server.devices, journal: server.journal, files: server.files });
    http = serve({ fetch: app.fetch, port: 0, hostname: '127.0.0.1' });
    await new Promise<void>((resolve) => http.once('listening', () => resolve()));
    baseUrl = `http://127.0.0.1:${(http.address() as AddressInfo).port}`;
  });
  afterEach(() => new Promise<void>((resolve) => http.close(() => resolve())));

  it('ожидающий запрос просыпается от новой пачки быстрее секунды', async () => {
    const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
    const started = Date.now();
    const waiting = fetch(`${baseUrl}/changes?after=0&wait=10`, { headers });
    await new Promise((resolve) => setTimeout(resolve, 200));
    const created = await fetch(`${baseUrl}/changes`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ batchId: 'live', ciphertext: 'AAAA' }),
    });
    expect(created.status).toBe(201);
    const body = (await (await waiting).json()) as ChangesBody;
    expect(body.items.map((item) => item.batchId)).toEqual(['live']);
    expect(Date.now() - started).toBeLessThan(1500);
  });
});
