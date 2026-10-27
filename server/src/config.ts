import { join } from 'node:path';
import { DEFAULT_PUSH_TIMING } from './push.js';

/** Ключ APNs команды для тихих пушей iPhone; без него пуши выключены. */
export interface ApnsConfig {
  keyFile: string;
  keyId: string;
  teamId: string;
  topic: string;
  /** Только для живой проверки: свой адрес вместо серверов Apple. */
  origin?: string;
}

export interface Config {
  port: number;
  dataDir: string;
  databasePath: string;
  backupDir: string;
  backupKeep: number;
  filesDir: string;
  filesLimitBytes: number;
  sharesDir: string;
  sharesLimitBytes: number;
  apns: ApnsConfig | null;
  pushMinIntervalMs: number;
}

export function readConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const dataDir = env.DATA_DIR ?? './data';
  return {
    port: Number(env.PORT ?? 3000),
    dataDir,
    databasePath: join(dataDir, 'mynotion-sync.db'),
    backupDir: join(dataDir, 'backups'),
    backupKeep: Number(env.BACKUP_KEEP ?? 14),
    filesDir: join(dataDir, 'files'),
    filesLimitBytes: Math.round(Number(env.FILES_LIMIT_GB ?? 50) * 1024 ** 3),
    sharesDir: join(dataDir, 'shares'),
    sharesLimitBytes: Math.round(Number(env.SHARES_LIMIT_GB ?? 10) * 1024 ** 3),
    apns:
      env.APNS_KEY_FILE && env.APNS_KEY_ID
        ? {
            keyFile: env.APNS_KEY_FILE,
            keyId: env.APNS_KEY_ID.trim(),
            // пустая переменная из docker-compose (`${APNS_TEAM_ID:-}`) — значение по умолчанию
            teamId: env.APNS_TEAM_ID?.trim() || 'DC5QSJ54MB',
            topic: env.APNS_TOPIC?.trim() || 'cloud.kurilov.mynotion.ios',
            origin: env.APNS_ORIGIN || undefined,
          }
        : null,
    pushMinIntervalMs: Number(env.PUSH_MIN_INTERVAL_SECONDS) > 0
      ? Number(env.PUSH_MIN_INTERVAL_SECONDS) * 1000
      : DEFAULT_PUSH_TIMING.minIntervalMs,
  };
}
