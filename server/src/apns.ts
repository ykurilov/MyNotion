import { createPrivateKey, sign, type KeyObject } from 'node:crypto';
import { connect, constants, type ClientHttp2Session } from 'node:http2';
import type { PushEnvironment, PushResult, PushSender } from './push.js';

export const APNS_ORIGINS: Record<PushEnvironment, string> = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
};

/** Apple просит менять JWT не чаще раза в 20 минут и принимает его час. */
const JWT_LIFETIME_MS = 40 * 60_000;
/** Тихий пуш, не доставленный за час, уже не нужен: следующая пачка пришлёт новый. */
const EXPIRATION_SECONDS = 3600;
const BODY = JSON.stringify({ aps: { 'content-available': 1 } });
/** Токен больше не годится: на него не слать. */
const DEAD_TOKEN_REASONS = new Set(['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered']);
const STALE_JWT_REASONS = new Set(['ExpiredProviderToken', 'InvalidProviderToken']);

export interface ApnsOptions {
  /** Ключ APNs (.p8, PEM). */
  keyPem: string;
  keyId: string;
  teamId: string;
  /** Bundle ID приложения iPhone. */
  topic: string;
  /** Подмена адресов Apple — для тестов и живой проверки. */
  origins?: Partial<Record<PushEnvironment, string>>;
  timeoutMs?: number;
  now?: () => number;
}

export interface ApnsSender extends PushSender {
  close(): void;
}

/** Фоновые пуши в Apple по HTTP/2 с JWT от ключа команды (без сертификатов). Не бросает: итог — в `PushResult`. */
export function createApnsSender(options: ApnsOptions): ApnsSender {
  const key: KeyObject = createPrivateKey(options.keyPem);
  const origins = { ...APNS_ORIGINS, ...options.origins };
  const timeoutMs = options.timeoutMs ?? 10_000;
  const now = options.now ?? Date.now;
  const sessions = new Map<string, ClientHttp2Session>();
  let jwt: { value: string; issuedAt: number } | null = null;

  function providerToken(): string {
    const time = now();
    if (jwt && time - jwt.issuedAt < JWT_LIFETIME_MS) return jwt.value;
    const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url');
    const unsigned = `${encode({ alg: 'ES256', kid: options.keyId })}.${encode({ iss: options.teamId, iat: Math.floor(time / 1000) })}`;
    const signature = sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
    jwt = { value: `${unsigned}.${signature}`, issuedAt: time };
    return jwt.value;
  }

  /** Одно соединение на адрес; оборвалось — следующее подключится заново. */
  function session(origin: string): ClientHttp2Session {
    const existing = sessions.get(origin);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const created = connect(origin);
    const forget = () => {
      if (sessions.get(origin) === created) sessions.delete(origin);
    };
    created.on('error', forget);
    created.on('close', forget);
    created.on('goaway', forget);
    // простаивающее соединение не держит процесс и закрывается само
    created.setTimeout(10 * 60_000, () => created.close());
    created.unref();
    sessions.set(origin, created);
    return created;
  }

  function send(deviceToken: string, environment: PushEnvironment): Promise<PushResult> {
    return new Promise<PushResult>((resolve) => {
      let settled = false;
      const finish = (result: PushResult) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (result.status !== undefined && STALE_JWT_REASONS.has(result.reason ?? '')) jwt = null;
        resolve(result);
      };
      const timer = setTimeout(() => {
        request?.close(constants.NGHTTP2_CANCEL);
        finish({ outcome: 'failed', reason: 'Timeout' });
      }, timeoutMs);
      let request: ReturnType<ClientHttp2Session['request']> | undefined;
      try {
        request = session(origins[environment]).request({
          ':method': 'POST',
          ':path': `/3/device/${deviceToken}`,
          authorization: `bearer ${providerToken()}`,
          'apns-push-type': 'background',
          'apns-priority': '5',
          'apns-topic': options.topic,
          'apns-expiration': String(Math.floor(now() / 1000) + EXPIRATION_SECONDS),
          'content-type': 'application/json',
        });
        let status = 0;
        let body = '';
        request.setEncoding('utf8');
        request.on('response', (headers) => (status = Number(headers[':status'])));
        request.on('data', (chunk: string) => (body += chunk));
        request.on('end', () => {
          let reason: string | undefined;
          try {
            reason = body ? (JSON.parse(body) as { reason?: string }).reason : undefined;
          } catch {
            reason = undefined;
          }
          if (status === 200) return finish({ outcome: 'sent', status });
          const dead = status === 410 || (status === 400 && DEAD_TOKEN_REASONS.has(reason ?? ''));
          finish({ outcome: dead ? 'unregistered' : 'failed', status, reason });
        });
        request.on('error', (error) => finish({ outcome: 'failed', reason: error.message }));
        // соединение оборвалось до ответа
        request.on('close', () => finish({ outcome: 'failed', status: status || undefined, reason: 'StreamClosed' }));
        request.end(BODY);
      } catch (error) {
        finish({ outcome: 'failed', reason: error instanceof Error ? error.message : String(error) });
      }
    });
  }

  return {
    send,
    close() {
      for (const client of sessions.values()) client.destroy();
      sessions.clear();
    },
  };
}
