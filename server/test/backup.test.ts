import { mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { backupDatabase } from '../src/backup.js';
import { openDatabase } from '../src/db.js';

describe('ежедневная копия базы', () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'mynotion-backup-'));
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('кладёт рабочую копию с датой в имени', async () => {
    const source = openDatabase(join(dir, 'source.db'));
    source.prepare("INSERT INTO meta (key, value) VALUES ('проверка', 42)").run();

    const file = await backupDatabase(source, join(dir, 'backups'), new Date('2026-10-18T03:00:00Z'));
    expect(file.endsWith('mynotion-sync-2026-10-18.db')).toBe(true);

    const copy = new Database(file, { readonly: true });
    expect(copy.prepare("SELECT value FROM meta WHERE key = 'проверка'").get()).toEqual({ value: 42 });
    copy.close();
  });

  it('хранит только указанное число последних копий', async () => {
    const source = openDatabase(join(dir, 'source.db'));
    for (let day = 1; day <= 5; day++) {
      await backupDatabase(source, join(dir, 'backups'), new Date(`2026-10-0${day}T03:00:00Z`), 3);
    }
    expect(readdirSync(join(dir, 'backups')).sort()).toEqual([
      'mynotion-sync-2026-10-03.db',
      'mynotion-sync-2026-10-04.db',
      'mynotion-sync-2026-10-05.db',
    ]);
  });
});
