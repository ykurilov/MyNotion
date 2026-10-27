import { generateKeyPairSync, verify } from 'node:crypto';
import { createServer, type Http2Server, type IncomingHttpHeaders, type ServerHttp2Stream } from 'node:http2';
import type { AddressInfo } from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import { createApnsSender, type ApnsSender } from '../src/apns.js';

const TOKEN = 'c3'.repeat(32);
const TEAM_ID = 'TEAM123456';
const KEY_ID = 'KEY1234567';
const TOPIC = 'cloud.kurilov.mynotion.ios';

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const KEY_PEM = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();

interface Received {
  headers: IncomingHttpHeaders;
  body: string;
}

type Answer = { status: number; body?: unknown } | 'silence';

/** Поддельный APNs: HTTP/2 без TLS, отвечает по очереди заданным. */
async function fakeApns(answers: Answer[] = []): Promise<{ origin: string; received: Received[]; server: Http2Server }> {
  const received: Received[] = [];
  const server = createServer();
  server.on('stream', (stream: ServerHttp2Stream, headers) => {
    let body = '';
    stream.setEncoding('utf8');
    stream.on('data', (chunk: string) => (body += chunk));
    stream.on('end', () => {
      received.push({ headers, body });
      const answer = answers.shift() ?? { status: 200 };
      if (answer === 'silence') return;
      stream.respond({ ':status': answer.status, ...(answer.body ? { 'content-type': 'application/json' } : {}) });
      stream.end(answer.body ? JSON.stringify(answer.body) : undefined);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  servers.push(server);
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, received, server };
}

const servers: Http2Server[] = [];
const senders: ApnsSender[] = [];
afterEach(async () => {
  for (const sender of senders.splice(0)) sender.close();
  await Promise.all(servers.splice(0).map((server) => new Promise((resolve) => server.close(resolve))));
});

function sender(origins: { sandbox: string; production: string }, options: { now?: () => number; timeoutMs?: number } = {}) {
  const created = createApnsSender({ keyPem: KEY_PEM, keyId: KEY_ID, teamId: TEAM_ID, topic: TOPIC, origins, ...options });
  senders.push(created);
  return created;
}

function decodeJwt(authorization: string | string[] | undefined) {
  const jwt = String(authorization).replace(/^bearer /, '');
  const [header, claims, signature] = jwt.split('.');
  const valid = verify(
    'sha256',
    Buffer.from(`${header}.${claims}`),
    { key: publicKey, dsaEncoding: 'ieee-p1363' },
    Buffer.from(signature!, 'base64url'),
  );
  return {
    jwt,
    valid,
    header: JSON.parse(Buffer.from(header!, 'base64url').toString()),
    claims: JSON.parse(Buffer.from(claims!, 'base64url').toString()),
  };
}

describe('отправка тихих пушей в Apple (APNs)', () => {
  it('фоновый пуш: путь, заголовки, пустое тело с content-available и подписанный ключом JWT', async () => {
    const apple = await fakeApns();
    const result = await sender({ sandbox: apple.origin, production: apple.origin }, { now: () => 1_800_000_000_000 }).send(TOKEN, 'sandbox');
    expect(result.outcome).toBe('sent');
    const [request] = apple.received;
    expect(request!.headers[':method']).toBe('POST');
    expect(request!.headers[':path']).toBe(`/3/device/${TOKEN}`);
    expect(request!.headers['apns-push-type']).toBe('background');
    expect(request!.headers['apns-priority']).toBe('5');
    expect(request!.headers['apns-topic']).toBe(TOPIC);
    expect(Number(request!.headers['apns-expiration'])).toBeGreaterThan(1_800_000_000);
    expect(JSON.parse(request!.body)).toEqual({ aps: { 'content-available': 1 } });
    const jwt = decodeJwt(request!.headers.authorization);
    expect(jwt.valid).toBe(true);
    expect(jwt.header).toEqual({ alg: 'ES256', kid: KEY_ID });
    expect(jwt.claims).toEqual({ iss: TEAM_ID, iat: 1_800_000_000 });
  });

  it('среда выбирает адрес Apple: sandbox для отладки, production для TestFlight', async () => {
    const sandbox = await fakeApns();
    const production = await fakeApns();
    const apns = sender({ sandbox: sandbox.origin, production: production.origin });
    await apns.send(TOKEN, 'production');
    await apns.send(TOKEN, 'sandbox');
    await apns.send(TOKEN, 'production');
    expect(sandbox.received).toHaveLength(1);
    expect(production.received).toHaveLength(2);
  });

  it('JWT один на 40 минут, потом новый; после ExpiredProviderToken — сразу новый', async () => {
    let now = 1_800_000_000_000;
    const apple = await fakeApns([{ status: 200 }, { status: 200 }, { status: 200 }, { status: 403, body: { reason: 'ExpiredProviderToken' } }]);
    const apns = sender({ sandbox: apple.origin, production: apple.origin }, { now: () => now });
    await apns.send(TOKEN, 'sandbox');
    now += 39 * 60_000;
    await apns.send(TOKEN, 'sandbox');
    now += 2 * 60_000;
    await apns.send(TOKEN, 'sandbox');
    const expired = await apns.send(TOKEN, 'sandbox');
    expect(expired).toMatchObject({ outcome: 'failed', status: 403, reason: 'ExpiredProviderToken' });
    now += 1_000;
    await apns.send(TOKEN, 'sandbox');
    const jwts = apple.received.map((request) => decodeJwt(request.headers.authorization).jwt);
    expect(jwts[1]).toBe(jwts[0]);
    expect(jwts[2]).not.toBe(jwts[1]);
    expect(jwts[3]).toBe(jwts[2]);
    expect(jwts[4]).not.toBe(jwts[3]);
  });

  it('ответы Apple: 410 и BadDeviceToken — токен мёртв; 500 и прочее — просто не вышло', async () => {
    const apple = await fakeApns([
      { status: 410, body: { reason: 'Unregistered' } },
      { status: 400, body: { reason: 'BadDeviceToken' } },
      { status: 400, body: { reason: 'DeviceTokenNotForTopic' } },
      { status: 500, body: { reason: 'InternalServerError' } },
      { status: 429, body: { reason: 'TooManyRequests' } },
    ]);
    const apns = sender({ sandbox: apple.origin, production: apple.origin });
    const outcomes = [];
    for (let i = 0; i < 5; i++) outcomes.push(await apns.send(TOKEN, 'sandbox'));
    expect(outcomes.map((result) => [result.outcome, result.reason])).toEqual([
      ['unregistered', 'Unregistered'],
      ['unregistered', 'BadDeviceToken'],
      ['unregistered', 'DeviceTokenNotForTopic'],
      ['failed', 'InternalServerError'],
      ['failed', 'TooManyRequests'],
    ]);
  });

  it('Apple молчит — «не вышло» по таймауту, следующая отправка работает', async () => {
    const apple = await fakeApns(['silence', { status: 200 }]);
    const apns = sender({ sandbox: apple.origin, production: apple.origin }, { timeoutMs: 300 });
    const started = Date.now();
    expect((await apns.send(TOKEN, 'sandbox')).outcome).toBe('failed');
    expect(Date.now() - started).toBeLessThan(3_000);
    expect((await apns.send(TOKEN, 'sandbox')).outcome).toBe('sent');
  });

  it('Apple недоступен — «не вышло», без исключения; связь вернулась — отправка идёт', async () => {
    const apple = await fakeApns();
    const origin = apple.origin;
    await new Promise((resolve) => apple.server.close(resolve));
    servers.splice(servers.indexOf(apple.server), 1);
    const apns = sender({ sandbox: origin, production: origin }, { timeoutMs: 1_000 });
    expect((await apns.send(TOKEN, 'sandbox')).outcome).toBe('failed');

    const port = Number(new URL(origin).port);
    const back = await fakeApns();
    await new Promise((resolve) => back.server.close(resolve));
    await new Promise<void>((resolve) => back.server.listen(port, '127.0.0.1', resolve));
    expect((await apns.send(TOKEN, 'sandbox')).outcome).toBe('sent');
  });
});
