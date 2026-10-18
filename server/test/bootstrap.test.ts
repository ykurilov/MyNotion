import { describe, expect, it } from 'vitest';
import { runBootstrap } from '../src/bootstrap.js';
import { openDatabase } from '../src/db.js';
import { createDevices } from '../src/devices.js';

function capture() {
  const lines: string[] = [];
  return { lines, write: (text: string) => void lines.push(text) };
}

describe('mynotion-sync bootstrap', () => {
  it('создаёт первое устройство и печатает токен один раз', () => {
    const db = openDatabase(':memory:');
    const out = capture();
    const code = runBootstrap(db, ['--name', 'Mac Юрия'], out.write);
    expect(code).toBe(0);

    const token = out.lines.join('').match(/[A-Za-z0-9_-]{40,}/)?.[0];
    expect(token).toBeDefined();
    expect(createDevices(db).authenticate(token!)).toMatchObject({ deviceName: 'Mac Юрия' });
  });

  it('--token-only печатает только токен', () => {
    const db = openDatabase(':memory:');
    const out = capture();
    runBootstrap(db, ['--name', 'Mac', '--token-only'], out.write);
    expect(out.lines.join('')).toMatch(/^[A-Za-z0-9_-]{40,}\n$/);
  });

  it('второй запуск отказывает и не печатает токен', () => {
    const db = openDatabase(':memory:');
    runBootstrap(db, ['--name', 'Mac'], capture().write);
    const out = capture();
    const code = runBootstrap(db, ['--name', 'Ещё Mac'], out.write);
    expect(code).toBe(1);
    expect(out.lines.join('')).toMatch(/уже есть/);
    expect(out.lines.join('')).not.toMatch(/[A-Za-z0-9_-]{40,}/);
  });
});
