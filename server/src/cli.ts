#!/usr/bin/env node
import { mkdirSync } from 'node:fs';
import { runBootstrap } from './bootstrap.js';
import { readConfig } from './config.js';
import { openDatabase } from './db.js';

const [command, ...args] = process.argv.slice(2);

if (command === 'bootstrap') {
  const config = readConfig();
  mkdirSync(config.dataDir, { recursive: true });
  const db = openDatabase(config.databasePath);
  const code = runBootstrap(db, args, (text) => void process.stdout.write(text));
  db.close();
  process.exit(code);
} else {
  console.error('Команды: mynotion-sync bootstrap --name "Имя Mac" [--token-only]');
  process.exit(command ? 2 : 0);
}
