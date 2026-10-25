import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll } from 'vitest';
import { createApp, type AppOptions } from '../src/app.js';
import { openDatabase, type Db } from '../src/db.js';
import { createDevices, type Devices } from '../src/devices.js';
import { createFiles, type Files } from '../src/files.js';
import { createJournal, type Journal } from '../src/journal.js';
import { createShares, type Shares } from '../src/shares.js';

const tempDirs: string[] = [];
afterAll(() => {
  for (const dir of tempDirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

export function makeTempDir(prefix = 'mynotion-test-'): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

export interface TestServer {
  db: Db;
  devices: Devices;
  journal: Journal;
  files: Files;
  filesDir: string;
  shares: Shares;
  app: ReturnType<typeof createApp>;
  firstDevice: { deviceId: string; token: string };
  call(method: string, path: string, options?: CallOptions): Promise<Response>;
}

export interface CallOptions {
  token?: string | null;
  body?: unknown;
  rawBody?: string;
  /** Тело как есть (части файлов): `application/octet-stream`. */
  binary?: BodyInit;
  headers?: Record<string, string>;
}

export interface FilesOptions {
  limitBytes?: number;
  now?: () => number;
}

export function createTestServer(limits?: AppOptions['limits'], filesOptions: FilesOptions = {}): TestServer {
  const db = openDatabase(':memory:');
  const devices = createDevices(db);
  const journal = createJournal(db, { devices });
  const filesDir = makeTempDir('mynotion-files-');
  const files = createFiles(db, { dir: filesDir, limitBytes: filesOptions.limitBytes ?? 1024 ** 3, now: filesOptions.now });
  const shares = createShares(db, { dir: makeTempDir('mynotion-shares-'), limitBytes: 1024 ** 3 });
  const app = createApp({ devices, journal, files, shares, limits });
  const firstDevice = devices.bootstrap('Первый Mac');
  return {
    db,
    devices,
    journal,
    files,
    filesDir,
    shares,
    app,
    firstDevice,
    call(method, path, options = {}) {
      const token = options.token === undefined ? firstDevice.token : options.token;
      const headers: Record<string, string> = {};
      if (token) headers.authorization = `Bearer ${token}`;
      Object.assign(headers, options.headers);
      let body: BodyInit | undefined;
      if (options.binary !== undefined) {
        body = options.binary;
        headers['content-type'] = 'application/octet-stream';
      } else if (options.rawBody !== undefined) {
        body = options.rawBody;
        headers['content-type'] = 'application/json';
      } else if (options.body !== undefined) {
        body = JSON.stringify(options.body);
        headers['content-type'] = 'application/json';
      }
      return Promise.resolve(app.request(path, { method, headers, body, ...(body instanceof ReadableStream ? { duplex: 'half' } : {}) } as RequestInit));
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
