import { join } from 'node:path';

export interface Config {
  port: number;
  dataDir: string;
  databasePath: string;
  backupDir: string;
  backupKeep: number;
}

export function readConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const dataDir = env.DATA_DIR ?? './data';
  return {
    port: Number(env.PORT ?? 3000),
    dataDir,
    databasePath: join(dataDir, 'mynotion-sync.db'),
    backupDir: join(dataDir, 'backups'),
    backupKeep: Number(env.BACKUP_KEEP ?? 14),
  };
}
