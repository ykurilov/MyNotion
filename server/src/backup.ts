import { existsSync, linkSync, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import Database from 'better-sqlite3';
import type { Db } from './db.js';
import { TMP_DIR } from './files.js';

const PREFIX = 'mynotion-sync-';
const SUFFIX = '.db';

/**
 * Цельная копия базы через встроенный механизм SQLite: безопасна при работающем сервере.
 * Снимки страниц по ссылке — открытый текст — в копию не идут: остаются ссылки, а снимки приложение
 * выложит заново после восстановления (их файлы в копию и так не попадают).
 */
export async function backupDatabase(db: Db, dir: string, date: Date, keep = 14): Promise<string> {
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${PREFIX}${date.toISOString().slice(0, 10)}${SUFFIX}`);
  await db.backup(file);
  const copy = new Database(file);
  try {
    copy.pragma('journal_mode = DELETE');
    copy.pragma('secure_delete = ON');
    copy.exec('UPDATE shares SET document = NULL, digest = NULL, published_at = NULL; DELETE FROM share_files; VACUUM;');
  } finally {
    copy.close();
  }
  const copies = readdirSync(dir)
    .filter((name) => name.startsWith(PREFIX) && name.endsWith(SUFFIX))
    .sort();
  for (const old of copies.slice(0, Math.max(0, copies.length - keep))) rmSync(join(dir, old));
  return file;
}

const FILES_PREFIX = 'files-';

/**
 * Копия папки файлов жёсткими ссылками (`cp -al`): части неизменны, поэтому копия почти не занимает места,
 * а стёртая с сервера часть ещё лежит в копиях, пока их не вытеснят новые.
 */
export async function backupFiles(filesDir: string, dir: string, date: Date, keep = 14): Promise<string> {
  mkdirSync(dir, { recursive: true });
  const target = join(dir, `${FILES_PREFIX}${date.toISOString().slice(0, 10)}`);
  rmSync(target, { recursive: true, force: true });
  mkdirSync(target);
  if (existsSync(filesDir)) linkTree(filesDir, target, true);
  const copies = readdirSync(dir)
    .filter((name) => name.startsWith(FILES_PREFIX))
    .sort();
  for (const old of copies.slice(0, Math.max(0, copies.length - keep))) rmSync(join(dir, old), { recursive: true, force: true });
  return target;
}

function linkTree(from: string, to: string, root = false): void {
  for (const entry of readdirSync(from, { withFileTypes: true })) {
    if (root && entry.name === TMP_DIR) continue;
    const source = join(from, entry.name);
    const copy = join(to, entry.name);
    if (entry.isDirectory()) {
      mkdirSync(copy);
      linkTree(source, copy);
    } else if (entry.isFile()) {
      linkSync(source, copy);
    }
  }
}
