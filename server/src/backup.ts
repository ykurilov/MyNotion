import { mkdirSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import type { Db } from './db.js';

const PREFIX = 'mynotion-sync-';
const SUFFIX = '.db';

/** Цельная копия базы через встроенный механизм SQLite: безопасна при работающем сервере. */
export async function backupDatabase(db: Db, dir: string, date: Date, keep = 14): Promise<string> {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${PREFIX}${date.toISOString().slice(0, 10)}${SUFFIX}`);
  await db.backup(file);
  const copies = readdirSync(dir)
    .filter((name) => name.startsWith(PREFIX) && name.endsWith(SUFFIX))
    .sort();
  for (const old of copies.slice(0, Math.max(0, copies.length - keep))) rmSync(join(dir, old));
  return file;
}
