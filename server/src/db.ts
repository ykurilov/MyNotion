import Database from 'better-sqlite3';

export type Db = Database.Database;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS devices (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  token_hash    TEXT NOT NULL UNIQUE,
  created_at    INTEGER NOT NULL,
  last_seen_at  INTEGER,
  last_ack_seq  INTEGER NOT NULL DEFAULT 0,
  disabled_at   INTEGER
);
CREATE TABLE IF NOT EXISTS invites (
  code_hash   TEXT PRIMARY KEY,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  used_at     INTEGER
);
CREATE TABLE IF NOT EXISTS batches (
  seq         INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_id    TEXT NOT NULL UNIQUE,
  device_id   TEXT NOT NULL,
  ciphertext  TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS batch_receipts (
  batch_id    TEXT PRIMARY KEY,
  seq         INTEGER NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS snapshot (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  seq         INTEGER NOT NULL,
  ciphertext  TEXT NOT NULL,
  created_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS files (
  id          TEXT PRIMARY KEY,
  part_count  INTEGER NOT NULL,
  bytes       INTEGER NOT NULL DEFAULT 0,
  complete_at INTEGER,
  deleted_at  INTEGER,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL
);
-- Доступ по ссылке: открытый снимок страницы, который собрало приложение (specs/006-share-link)
CREATE TABLE IF NOT EXISTS shares (
  page_id           TEXT PRIMARY KEY,
  token             TEXT NOT NULL UNIQUE,
  enabled           INTEGER NOT NULL,
  include_subpages  INTEGER NOT NULL DEFAULT 1,
  document          TEXT,
  digest            TEXT,
  published_at      INTEGER,
  created_at        INTEGER NOT NULL,
  updated_at        INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS share_files (
  page_id     TEXT NOT NULL,
  file_id     TEXT NOT NULL,
  bytes       INTEGER NOT NULL,
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (page_id, file_id)
);
CREATE TABLE IF NOT EXISTS meta (
  key    TEXT PRIMARY KEY,
  value  INTEGER NOT NULL
);
`;

export function openDatabase(path: string): Db {
  const db = new Database(path);
  db.pragma('journal_mode = WAL');
  db.pragma('synchronous = NORMAL');
  db.exec(SCHEMA);
  return db;
}
