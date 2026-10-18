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
