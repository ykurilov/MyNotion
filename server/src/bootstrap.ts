import type { Db } from './db.js';
import { createDevices } from './devices.js';

/** `mynotion-sync bootstrap --name "Mac Юрия" [--token-only]`: первое устройство, токен печатается один раз. */
export function runBootstrap(db: Db, args: string[], write: (text: string) => void): number {
  const nameIndex = args.indexOf('--name');
  const name = (nameIndex >= 0 ? args[nameIndex + 1] : undefined)?.trim() || 'Первый Mac';
  const tokenOnly = args.includes('--token-only');

  const devices = createDevices(db);
  if (devices.list().length > 0) {
    write('Первое устройство уже есть. Новые подключаются приглашением из приложения.\n');
    return 1;
  }
  const { deviceId, token } = devices.bootstrap(name);
  if (tokenOnly) {
    write(`${token}\n`);
  } else {
    write(`Устройство «${name}» создано (${deviceId}).\nТокен показан один раз, сохраните его сразу:\n${token}\n`);
  }
  return 0;
}
