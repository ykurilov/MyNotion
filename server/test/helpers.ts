import { createApp, type AppOptions } from '../src/app.js';
import { openDatabase, type Db } from '../src/db.js';
import { createDevices, type Devices } from '../src/devices.js';
import { createJournal, type Journal } from '../src/journal.js';

export interface TestServer {
  db: Db;
  devices: Devices;
  journal: Journal;
  app: ReturnType<typeof createApp>;
  firstDevice: { deviceId: string; token: string };
  call(method: string, path: string, options?: CallOptions): Promise<Response>;
}

export interface CallOptions {
  token?: string | null;
  body?: unknown;
  rawBody?: string;
}

export function createTestServer(limits?: AppOptions['limits']): TestServer {
  const db = openDatabase(':memory:');
  const devices = createDevices(db);
  const journal = createJournal(db, { devices });
  const app = createApp({ devices, journal, limits });
  const firstDevice = devices.bootstrap('Первый Mac');
  return {
    db,
    devices,
    journal,
    app,
    firstDevice,
    call(method, path, options = {}) {
      const token = options.token === undefined ? firstDevice.token : options.token;
      const headers: Record<string, string> = {};
      if (token) headers.authorization = `Bearer ${token}`;
      let body: string | undefined;
      if (options.rawBody !== undefined) {
        body = options.rawBody;
        headers['content-type'] = 'application/json';
      } else if (options.body !== undefined) {
        body = JSON.stringify(options.body);
        headers['content-type'] = 'application/json';
      }
      return Promise.resolve(app.request(path, { method, headers, body }));
    },
  };
}

/** Присоединяет ещё одно устройство через настоящее приглашение. */
export async function joinDevice(server: TestServer, name: string): Promise<{ deviceId: string; token: string }> {
  const invite = (await (await server.call('POST', '/devices/invite')).json()) as { inviteCode: string };
  const joined = (await (
    await server.call('POST', '/devices/join', { token: null, body: { inviteCode: invite.inviteCode, deviceName: name } })
  ).json()) as { deviceId: string; deviceToken: string };
  return { deviceId: joined.deviceId, token: joined.deviceToken };
}

/** Шифротекст нужного размера в байтах до base64. */
export function ciphertextOf(decodedBytes: number, fill = 7): string {
  return Buffer.alloc(decodedBytes, fill).toString('base64');
}

export function expectRussianError(body: unknown, code: string): void {
  const error = body as { error?: string; message?: string };
  if (error.error !== code) throw new Error(`ожидался код ${code}, пришло ${JSON.stringify(body)}`);
  if (!error.message || !/[А-Яа-яЁё]/.test(error.message)) {
    throw new Error(`сообщение должно быть по-русски: ${JSON.stringify(body)}`);
  }
}
