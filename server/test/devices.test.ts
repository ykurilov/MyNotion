import { createHash } from 'node:crypto';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createTestServer, expectRussianError, joinDevice, type TestServer } from './helpers.js';

const sha256 = (value: string) => createHash('sha256').update(value).digest('hex');
const START = new Date('2026-10-18T10:00:00.000Z');

describe('устройства и приглашения', () => {
  let server: TestServer;

  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(START);
    server = createTestServer();
  });
  afterEach(() => vi.useRealTimers());

  it('/health отвечает без авторизации', async () => {
    const response = await server.call('GET', '/health', { token: null });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: 'ok' });
  });

  it('без токена или с чужим токеном — 401 в едином виде', async () => {
    for (const token of [null, 'not-a-real-token']) {
      const response = await server.call('GET', '/devices', { token });
      expect(response.status).toBe(401);
      expectRussianError(await response.json(), 'unauthorized');
    }
  });

  it('неизвестный путь — 404 в едином виде', async () => {
    const response = await server.call('GET', '/нет-такого');
    expect(response.status).toBe(404);
    expectRussianError(await response.json(), 'not_found');
  });

  it('приглашение: 201, срок 15 минут', async () => {
    const response = await server.call('POST', '/devices/invite');
    expect(response.status).toBe(201);
    const body = (await response.json()) as { inviteCode: string; expiresAt: string };
    expect(body.inviteCode.length).toBeGreaterThanOrEqual(16);
    expect(body.expiresAt).toBe('2026-10-18T10:15:00.000Z');
  });

  it('приглашение создаёт только авторизованное устройство', async () => {
    const response = await server.call('POST', '/devices/invite', { token: null });
    expect(response.status).toBe(401);
  });

  it('join: 201 с токеном, новое устройство работает, приглашение одноразовое', async () => {
    const invite = (await (await server.call('POST', '/devices/invite')).json()) as { inviteCode: string };
    const joinBody = { inviteCode: invite.inviteCode, deviceName: 'MacBook Юрия' };

    const response = await server.call('POST', '/devices/join', { token: null, body: joinBody });
    expect(response.status).toBe(201);
    const joined = (await response.json()) as { deviceId: string; deviceToken: string; latestSnapshotSeq: number | null };
    expect(joined.deviceId).toMatch(/^[0-9a-f-]{36}$/);
    expect(joined.deviceToken.length).toBeGreaterThanOrEqual(32);
    expect(joined.latestSnapshotSeq).toBeNull();

    const list = await server.call('GET', '/devices', { token: joined.deviceToken });
    expect(list.status).toBe(200);

    const again = await server.call('POST', '/devices/join', { token: null, body: joinBody });
    expect(again.status).toBe(410);
    expectRussianError(await again.json(), 'invite_expired');
  });

  it('join: за секунду до конца срока работает, после — 410', async () => {
    const fresh = (await (await server.call('POST', '/devices/invite')).json()) as { inviteCode: string };
    vi.setSystemTime(new Date(START.getTime() + 15 * 60_000 - 1000));
    const inTime = await server.call('POST', '/devices/join', {
      token: null,
      body: { inviteCode: fresh.inviteCode, deviceName: 'Успел' },
    });
    expect(inTime.status).toBe(201);

    vi.setSystemTime(START);
    const late = (await (await server.call('POST', '/devices/invite')).json()) as { inviteCode: string };
    vi.setSystemTime(new Date(START.getTime() + 15 * 60_000 + 1000));
    const expired = await server.call('POST', '/devices/join', {
      token: null,
      body: { inviteCode: late.inviteCode, deviceName: 'Опоздал' },
    });
    expect(expired.status).toBe(410);
    expectRussianError(await expired.json(), 'invite_expired');
  });

  it('join: неизвестный код — 410, пустое имя — 400', async () => {
    const unknown = await server.call('POST', '/devices/join', {
      token: null,
      body: { inviteCode: 'LEVYJ-KOD', deviceName: 'Mac' },
    });
    expect(unknown.status).toBe(410);

    const invite = (await (await server.call('POST', '/devices/invite')).json()) as { inviteCode: string };
    const noName = await server.call('POST', '/devices/join', {
      token: null,
      body: { inviteCode: invite.inviteCode, deviceName: '  ' },
    });
    expect(noName.status).toBe(400);
    expectRussianError(await noName.json(), 'bad_request');
  });

  it('GET /devices: поля устройства, lastSeenAt обновляется', async () => {
    const second = await joinDevice(server, 'MacBook Юрия');
    vi.setSystemTime(new Date(START.getTime() + 60_000));
    await server.call('GET', '/devices', { token: second.token });

    const list = (await (await server.call('GET', '/devices')).json()) as Array<Record<string, unknown>>;
    expect(list).toHaveLength(2);
    const entry = list.find((device) => device.deviceId === second.deviceId)!;
    expect(entry).toEqual({
      deviceId: second.deviceId,
      deviceName: 'MacBook Юрия',
      lastSeenAt: '2026-10-18T10:01:00.000Z',
      lastAckSeq: 0,
    });
  });

  it('DELETE: 204, токен отключённого устройства получает 401, в списке его нет', async () => {
    const second = await joinDevice(server, 'Потерянный Mac');
    const response = await server.call('DELETE', `/devices/${second.deviceId}`);
    expect(response.status).toBe(204);

    const afterwards = await server.call('GET', '/devices', { token: second.token });
    expect(afterwards.status).toBe(401);

    const list = (await (await server.call('GET', '/devices')).json()) as Array<{ deviceId: string }>;
    expect(list.map((device) => device.deviceId)).toEqual([server.firstDevice.deviceId]);
  });

  it('DELETE: повтор — 204, неизвестный id — 404', async () => {
    const second = await joinDevice(server, 'Mac');
    await server.call('DELETE', `/devices/${second.deviceId}`);
    expect((await server.call('DELETE', `/devices/${second.deviceId}`)).status).toBe(204);
    const unknown = await server.call('DELETE', '/devices/00000000-0000-0000-0000-000000000000');
    expect(unknown.status).toBe(404);
    expectRussianError(await unknown.json(), 'not_found');
  });

  it('в базе только sha256 токенов и приглашений', async () => {
    const invite = (await (await server.call('POST', '/devices/invite')).json()) as { inviteCode: string };
    const joined = (await (
      await server.call('POST', '/devices/join', { token: null, body: { inviteCode: invite.inviteCode, deviceName: 'Mac' } })
    ).json()) as { deviceToken: string };

    const hashes = (server.db.prepare('SELECT token_hash FROM devices').all() as Array<{ token_hash: string }>).map(
      (row) => row.token_hash,
    );
    expect(hashes).toContain(sha256(server.firstDevice.token));
    expect(hashes).toContain(sha256(joined.deviceToken));
    expect(hashes).not.toContain(joined.deviceToken);

    const inviteHashes = (server.db.prepare('SELECT code_hash FROM invites').all() as Array<{ code_hash: string }>).map(
      (row) => row.code_hash,
    );
    expect(inviteHashes).toEqual([sha256(invite.inviteCode)]);

    const dump = JSON.stringify(server.db.prepare('SELECT * FROM devices').all());
    expect(dump).not.toContain(server.firstDevice.token);
    expect(dump).not.toContain(joined.deviceToken);
  });

  it('bootstrap создаёт первое устройство один раз', () => {
    expect(() => server.devices.bootstrap('Второй первый')).toThrow();
  });

  it('кривой JSON — 400 в едином виде', async () => {
    const response = await server.call('POST', '/devices/join', { token: null, rawBody: '{не json' });
    expect(response.status).toBe(400);
    expectRussianError(await response.json(), 'bad_request');
  });
});
