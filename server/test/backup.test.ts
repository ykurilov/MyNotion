import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Database from 'better-sqlite3';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { backupDatabase, backupFiles } from '../src/backup.js';
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

describe('ежедневная копия файлов', () => {
  let dir: string;
  let filesDir: string;
  let backups: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), 'mynotion-files-backup-'));
    filesDir = join(dir, 'files');
    backups = join(dir, 'backups');
    mkdirSync(join(filesDir, 'ab', 'abcd'), { recursive: true });
    writeFileSync(join(filesDir, 'ab', 'abcd', '0.part'), 'часть');
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it('копирует папку жёсткими ссылками в backups/files-<дата>', async () => {
    const target = await backupFiles(filesDir, backups, new Date('2026-10-18T03:00:00Z'));
    expect(target.endsWith('files-2026-10-18')).toBe(true);
    const original = join(filesDir, 'ab', 'abcd', '0.part');
    const copy = join(target, 'ab', 'abcd', '0.part');
    expect(readFileSync(copy, 'utf8')).toBe('часть');
    expect(statSync(copy).ino).toBe(statSync(original).ino);
    expect(statSync(original).nlink).toBe(2);
  });

  it('стёртая с сервера часть остаётся в копии', async () => {
    const target = await backupFiles(filesDir, backups, new Date('2026-10-18T03:00:00Z'));
    rmSync(join(filesDir, 'ab'), { recursive: true });
    expect(readFileSync(join(target, 'ab', 'abcd', '0.part'), 'utf8')).toBe('часть');
  });

  it('не копирует временные файлы записи', async () => {
    mkdirSync(join(filesDir, '.tmp'));
    writeFileSync(join(filesDir, '.tmp', 'x.tmp'), 'мусор');
    const target = await backupFiles(filesDir, backups, new Date('2026-10-18T03:00:00Z'));
    expect(existsSync(join(target, '.tmp'))).toBe(false);
  });

  it('хранит 14 копий по умолчанию и не трогает копии базы', async () => {
    const source = openDatabase(join(dir, 'source.db'));
    await backupDatabase(source, backups, new Date('2026-09-01T03:00:00Z'));
    for (let day = 1; day <= 16; day++) {
      await backupFiles(filesDir, backups, new Date(Date.UTC(2026, 9, day, 3)));
    }
    const names = readdirSync(backups);
    const copies = names.filter((name) => name.startsWith('files-')).sort();
    expect(copies).toHaveLength(14);
    expect(copies[0]).toBe('files-2026-10-03');
    expect(copies.at(-1)).toBe('files-2026-10-16');
    expect(names).toContain('mynotion-sync-2026-09-01.db');
  });

  it('повторная копия за ту же дату заменяет прежнюю', async () => {
    const date = new Date('2026-10-18T03:00:00Z');
    await backupFiles(filesDir, backups, date);
    writeFileSync(join(filesDir, 'ab', 'abcd', '1.part'), 'новая');
    const target = await backupFiles(filesDir, backups, date);
    expect(readdirSync(join(target, 'ab', 'abcd')).sort()).toEqual(['0.part', '1.part']);
  });

  it('нет папки файлов — копия пустая, без ошибки', async () => {
    rmSync(filesDir, { recursive: true });
    const target = await backupFiles(filesDir, backups, new Date('2026-10-18T03:00:00Z'));
    expect(readdirSync(target)).toEqual([]);
  });
});
