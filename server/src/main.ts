import { serve } from '@hono/node-server';
import { mkdirSync } from 'node:fs';
import type { Server } from 'node:http';
import { createApp } from './app.js';
import { backupDatabase, backupFiles } from './backup.js';
import { readConfig } from './config.js';
import { openDatabase } from './db.js';
import { createDevices } from './devices.js';
import { createFiles } from './files.js';
import { createJournal } from './journal.js';

const DAY_MS = 24 * 3600_000;
const config = readConfig();
mkdirSync(config.dataDir, { recursive: true });
const db = openDatabase(config.databasePath);
const devices = createDevices(db);
const journal = createJournal(db, { devices });
const files = createFiles(db, { dir: config.filesDir, limitBytes: config.filesLimitBytes });

const server = serve({ fetch: createApp({ devices, journal, files }).fetch, port: config.port }) as Server;
// долгое ожидание держит запрос до 25 с: сокеты не рвём раньше
server.keepAliveTimeout = 65_000;
server.requestTimeout = 0;
console.log(`mynotion-sync слушает порт ${config.port}, база: ${config.databasePath}`);

async function dailyBackup(): Promise<void> {
  try {
    const file = await backupDatabase(db, config.backupDir, new Date(), config.backupKeep);
    console.log(`Копия базы: ${file}`);
  } catch (error) {
    console.error('Копия базы не создана:', error instanceof Error ? error.message : error);
  }
}
async function dailyFilesBackup(): Promise<void> {
  try {
    const target = await backupFiles(config.filesDir, config.backupDir, new Date(), config.backupKeep);
    console.log(`Копия файлов: ${target}`);
  } catch (error) {
    console.error('Копия файлов не создана:', error instanceof Error ? error.message : error);
  }
}

/** Корзину и брошенные загрузки стираем до копии: в копию попадает уже убранное состояние. */
function dailyFilesSweep(): void {
  try {
    const { trashErased, abandonedErased } = files.sweep();
    if (trashErased + abandonedErased > 0) {
      console.log(`Уборка файлов: из корзины ${trashErased}, брошенных загрузок ${abandonedErased}`);
    }
  } catch (error) {
    console.error('Уборка файлов не удалась:', error instanceof Error ? error.message : error);
  }
}

async function dailyRoutine(): Promise<void> {
  await dailyBackup();
  await dailyFilesBackup();
  dailyFilesSweep();
}
void dailyRoutine();
setInterval(() => void dailyRoutine(), DAY_MS).unref();

for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    server.close();
    db.close();
    process.exit(0);
  });
}
