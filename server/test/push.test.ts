import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { DEFAULT_PUSH_TIMING, type PushSender } from '../src/push.js';
import { createTestServer, expectRussianError, joinDevice, type SentPush, type TestServer } from './helpers.js';

const PHONE_TOKEN = 'a1'.repeat(32);
const OTHER_TOKEN = 'b2'.repeat(32);
const { debounceMs, minIntervalMs, onlineGraceMs, recheckMs } = DEFAULT_PUSH_TIMING;

let batchNumber = 0;
const postBatch = (server: TestServer, token?: string) =>
  server.call('POST', '/changes', { token, body: { batchId: `b-${++batchNumber}`, ciphertext: 'AAAA' } });
const registerToken = (server: TestServer, token: string, body: unknown) =>
  server.call('PUT', '/devices/me/push-token', { token, body });
const pushTokensInDb = (server: TestServer) =>
  server.db.prepare('SELECT device_id AS deviceId, token, environment FROM push_tokens ORDER BY device_id').all();

describe('тихие пуши iPhone', () => {
  let server: TestServer;
  let phone: { deviceId: string; token: string };

  beforeEach(async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-10-27T10:00:00.000Z'));
    server = createTestServer();
    phone = await joinDevice(server, 'iPhone Юрия');
  });
  afterEach(() => {
    server.push.close();
    vi.useRealTimers();
  });

  /** iPhone зарегистрировал токен и ушёл со связи: следующие пуши — только по правилам схлопывания. */
  async function phoneRegisteredAndAsleep(environment = 'sandbox'): Promise<void> {
    expect((await registerToken(server, phone.token, { token: PHONE_TOKEN, environment })).status).toBe(204);
    await vi.advanceTimersByTimeAsync(onlineGraceMs + 1);
  }

  describe('регистрация токена', () => {
    it('устройство кладёт свой токен и среду: 204, в базе одна строка', async () => {
      const response = await registerToken(server, phone.token, { token: PHONE_TOKEN.toUpperCase(), environment: 'production' });
      expect(response.status).toBe(204);
      expect(pushTokensInDb(server)).toEqual([{ deviceId: phone.deviceId, token: PHONE_TOKEN, environment: 'production' }]);
    });

    it('новый токен того же устройства заменяет старый', async () => {
      await registerToken(server, phone.token, { token: PHONE_TOKEN, environment: 'sandbox' });
      await registerToken(server, phone.token, { token: OTHER_TOKEN, environment: 'production' });
      expect(pushTokensInDb(server)).toEqual([{ deviceId: phone.deviceId, token: OTHER_TOKEN, environment: 'production' }]);
    });

    it('тот же токен у нового устройства (iPhone подключили заново) уходит от старого', async () => {
      await registerToken(server, phone.token, { token: PHONE_TOKEN, environment: 'sandbox' });
      const again = await joinDevice(server, 'iPhone Юрия');
      await registerToken(server, again.token, { token: PHONE_TOKEN, environment: 'sandbox' });
      expect(pushTokensInDb(server)).toEqual([{ deviceId: again.deviceId, token: PHONE_TOKEN, environment: 'sandbox' }]);
    });

    it('кривой токен или среда — 400, без авторизации — 401', async () => {
      for (const body of [{}, { token: 'xyz', environment: 'sandbox' }, { token: PHONE_TOKEN }, { token: PHONE_TOKEN, environment: 'dev' }]) {
        const response = await registerToken(server, phone.token, body);
        expect(response.status).toBe(400);
        expectRussianError(await response.json(), 'bad_request');
      }
      expect((await registerToken(server, null as unknown as string, { token: PHONE_TOKEN, environment: 'sandbox' })).status).toBe(401);
      expect(pushTokensInDb(server)).toEqual([]);
    });

    it('удалённое устройство теряет токен и пушей не получает', async () => {
      await phoneRegisteredAndAsleep();
      expect((await server.call('DELETE', `/devices/${phone.deviceId}`)).status).toBe(204);
      expect(pushTokensInDb(server)).toEqual([]);
      await postBatch(server);
      await vi.advanceTimersByTimeAsync(minIntervalMs * 2);
      expect(server.pushes).toEqual([]);
    });

    it('без ключа Apple токены всё равно принимаются, пачки — как обычно', async () => {
      server = createTestServer(undefined, { pushSender: null });
      phone = await joinDevice(server, 'iPhone');
      expect((await registerToken(server, phone.token, { token: PHONE_TOKEN, environment: 'sandbox' })).status).toBe(204);
      expect((await postBatch(server)).status).toBe(201);
      await vi.advanceTimersByTimeAsync(minIntervalMs);
    });
  });

  describe('когда будить', () => {
    it('пачка с Mac будит спящий iPhone одним пушем его токеном и средой', async () => {
      await phoneRegisteredAndAsleep('production');
      expect((await postBatch(server)).status).toBe(201);
      expect(server.pushes).toEqual([]);
      await vi.advanceTimersByTimeAsync(debounceMs);
      expect(server.pushes).toEqual<SentPush[]>([{ deviceToken: PHONE_TOKEN, environment: 'production' }]);
    });

    it('пачка самого iPhone его не будит', async () => {
      await phoneRegisteredAndAsleep();
      await postBatch(server, phone.token);
      await vi.advanceTimersByTimeAsync(minIntervalMs * 2);
      expect(server.pushes).toEqual([]);
    });

    it('повтор той же пачки (тот же batchId) не будит ещё раз', async () => {
      await phoneRegisteredAndAsleep();
      const body = { batchId: 'same', ciphertext: 'AAAA' };
      await server.call('POST', '/changes', { body });
      await vi.advanceTimersByTimeAsync(debounceMs);
      await server.call('POST', '/ack', { token: phone.token, body: { seq: 1 } });
      await vi.advanceTimersByTimeAsync(onlineGraceMs + 1);
      expect((await server.call('POST', '/changes', { body })).status).toBe(200);
      await vi.advanceTimersByTimeAsync(minIntervalMs * 2);
      expect(server.pushes).toHaveLength(1);
    });

    it('серия пачек подряд — один пуш', async () => {
      await phoneRegisteredAndAsleep();
      for (let i = 0; i < 5; i++) await postBatch(server);
      await vi.advanceTimersByTimeAsync(debounceMs);
      expect(server.pushes).toHaveLength(1);
    });

    it('после пуша — не чаще раза в интервал: следующая пачка будит в конце интервала', async () => {
      await phoneRegisteredAndAsleep();
      await postBatch(server);
      await vi.advanceTimersByTimeAsync(debounceMs);
      expect(server.pushes).toHaveLength(1);

      await vi.advanceTimersByTimeAsync(60_000);
      await postBatch(server);
      await postBatch(server);
      // первый пуш ушёл на debounceMs, сейчас debounceMs + 60 с: до конца интервала — ещё (интервал − 60 с)
      await vi.advanceTimersByTimeAsync(minIntervalMs - 60_000 - 1_000);
      expect(server.pushes).toHaveLength(1);
      await vi.advanceTimersByTimeAsync(2_000);
      expect(server.pushes).toHaveLength(2);
    });

    it('iPhone сам забрал пачки до конца интервала — второго пуша нет', async () => {
      await phoneRegisteredAndAsleep();
      await postBatch(server);
      await vi.advanceTimersByTimeAsync(debounceMs);
      const seq = ((await (await postBatch(server)).json()) as { seq: number }).seq;
      // проснулся по первому пушу и забрал всё, включая вторую пачку
      expect((await server.call('POST', '/ack', { token: phone.token, body: { seq } })).status).toBe(200);
      await vi.advanceTimersByTimeAsync(minIntervalMs * 2);
      expect(server.pushes).toHaveLength(1);
    });

    it('iPhone на связи (ждёт пачки) — не будить; пропал, не забрав, — разбудить', async () => {
      await phoneRegisteredAndAsleep();
      // долгое ожидание iPhone, как на переднем плане
      const polling = server.call('GET', '/changes?after=0&wait=25', { token: phone.token });
      await vi.advanceTimersByTimeAsync(1_000);
      await postBatch(server);
      await polling; // пачка пришла ему прямо в ожидание — но подтвердить он не успел: приложение заморозили
      await vi.advanceTimersByTimeAsync(debounceMs);
      expect(server.pushes).toEqual([]);

      await vi.advanceTimersByTimeAsync(recheckMs + onlineGraceMs);
      expect(server.pushes).toHaveLength(1);
    });

    it('iPhone на связи и всё подтвердил — пуша нет совсем', async () => {
      await phoneRegisteredAndAsleep();
      const polling = server.call('GET', '/changes?after=0&wait=25', { token: phone.token });
      await vi.advanceTimersByTimeAsync(1_000);
      const { seq } = (await (await postBatch(server)).json()) as { seq: number };
      await polling;
      await server.call('POST', '/ack', { token: phone.token, body: { seq } });
      await vi.advanceTimersByTimeAsync(minIntervalMs * 2);
      expect(server.pushes).toEqual([]);
    });
  });

  describe('ответы Apple', () => {
    function serverWithSender(send: PushSender['send']) {
      server = createTestServer(undefined, { pushSender: { send } });
    }

    it('Apple отверг токен (410 или BadDeviceToken) — токен забывается', async () => {
      for (const answer of [{ status: 410, reason: 'Unregistered' }, { status: 400, reason: 'BadDeviceToken' }]) {
        const sent: string[] = [];
        serverWithSender(async (deviceToken) => {
          sent.push(deviceToken);
          return { outcome: 'unregistered', ...answer };
        });
        phone = await joinDevice(server, 'iPhone');
        await phoneRegisteredAndAsleep();
        await postBatch(server);
        await vi.advanceTimersByTimeAsync(debounceMs);
        expect(sent).toEqual([PHONE_TOKEN]);
        expect(pushTokensInDb(server)).toEqual([]);
        await postBatch(server);
        await vi.advanceTimersByTimeAsync(minIntervalMs * 2);
        expect(sent).toHaveLength(1);
        server.push.close();
      }
    });

    it('Apple не отвечает — пачка всё равно принята сразу', async () => {
      const sent: string[] = [];
      serverWithSender((deviceToken) => {
        sent.push(deviceToken);
        return new Promise(() => {});
      });
      phone = await joinDevice(server, 'iPhone');
      await phoneRegisteredAndAsleep();
      expect((await postBatch(server)).status).toBe(201);
      await vi.advanceTimersByTimeAsync(debounceMs);
      expect(sent).toHaveLength(1);
      expect((await postBatch(server)).status).toBe(201);
    });

    it('отправка упала — пачки принимаются, сервер не падает, токен остаётся', async () => {
      serverWithSender(async () => {
        throw new Error('сеть пропала');
      });
      phone = await joinDevice(server, 'iPhone');
      await phoneRegisteredAndAsleep();
      expect((await postBatch(server)).status).toBe(201);
      await vi.advanceTimersByTimeAsync(debounceMs);
      expect((await postBatch(server)).status).toBe(201);
      expect(pushTokensInDb(server)).toHaveLength(1);
    });
  });
});
