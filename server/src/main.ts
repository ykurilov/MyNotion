import { serve } from '@hono/node-server';
import { mkdirSync } from 'node:fs';
import type { Server } from 'node:http';
import { createApp } from './app.js';
import { backupDatabase } from './backup.js';
import { readConfig } from './config.js';
import { openDatabase } from './db.js';
import { createDevices } from './devices.js';
import { createJournal } from './journal.js';

const DAY_MS = 24 * 3600_000;
const config = readConfig();
mkdirSync(config.dataDir, { recursive: true });
const db = openDatabase(config.databasePath);
const devices = createDevices(db);
const journal = createJournal(db, { devices });

const server = serve({ fetch: createApp({ devices, journal }).fetch, port: config.port }) as Server;
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
void dailyBackup();
setInterval(() => void dailyBackup(), DAY_MS).unref();

for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    server.close();
    db.close();
    process.exit(0);
  });
}
