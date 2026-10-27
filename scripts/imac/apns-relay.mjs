// Подменный APNs для живой проверки (scripts/imac/iphone-sync-live-check.zsh): сервер синхронизации шлёт сюда
// тихие пуши как в Apple (HTTP/2 без TLS), а этот ретранслятор отдаёт их в симулятор командой `xcrun simctl push`.
// Каждый пуш — строка в журнале: путь с токеном, заголовки APNs и тело.
//
//   node apns-relay.mjs <порт> <файл с UDID симулятора> <bundle id> <журнал>
import { execFile } from 'node:child_process';
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http2';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [port, deviceFile, bundle, logFile] = process.argv.slice(2);
let count = 0;

const server = createServer();
server.on('stream', (stream, headers) => {
  let body = '';
  stream.setEncoding('utf8');
  stream.on('data', (chunk) => (body += chunk));
  stream.on('end', () => {
    const payload = join(tmpdir(), `apns-relay-${process.pid}-${++count}.json`);
    writeFileSync(payload, body);
    const device = readFileSync(deviceFile, 'utf8').trim();
    execFile('xcrun', ['simctl', 'push', device, bundle, payload], (error) => {
      appendFileSync(
        logFile,
        `${new Date().toISOString()} ${headers[':path']} push-type=${headers['apns-push-type']} priority=${headers['apns-priority']} ` +
          `topic=${headers['apns-topic']} jwt=${String(headers.authorization).startsWith('bearer ey')} ${body}` +
          `${error ? ` simctl-error=${error.message}` : ''}\n`,
      );
      stream.respond({ ':status': error ? 500 : 200 });
      stream.end();
    });
  });
});
server.listen(Number(port), '127.0.0.1');
