import { execFileSync, spawn, type ChildProcess } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { devices, expect, test } from '@playwright/test';
import { block, digestOf, IMAGE, page, PNG_1x1, richDocument, ROOT } from '../test/share-fixtures.js';

const DATABASE = '0193a000-0000-7000-8000-000000000003';
const SCREENSHOTS = join(import.meta.dirname, '..', 'e2e-results', 'screenshots');

let server: ChildProcess;
let base = '';
let deviceToken = '';
let dataDir = '';

const freePort = () =>
  new Promise<number>((resolve) => {
    const probe = createServer().listen(0, '127.0.0.1', () => {
      const { port } = probe.address() as { port: number };
      probe.close(() => resolve(port));
    });
  });

async function api(method: string, path: string, body?: unknown, binary?: Buffer): Promise<Response> {
  const headers: Record<string, string> = { authorization: `Bearer ${deviceToken}` };
  if (body !== undefined) headers['content-type'] = 'application/json';
  if (binary) headers['content-type'] = 'application/octet-stream';
  return fetch(base + path, {
    method,
    headers,
    body: binary ? new Uint8Array(binary) : body === undefined ? undefined : JSON.stringify(body),
  });
}

/** Страница со всеми видами блоков и встроенной базой, опубликованная по новой ссылке. */
async function publishedLink(pageId = ROOT): Promise<string> {
  const share = (await (await api('PUT', `/shares/${pageId}`, { enabled: true, includeSubpages: true })).json()) as { token: string };
  const document = richDocument() as { rootPageId: string; pages: Record<string, unknown>[] };
  document.rootPageId = pageId;
  document.pages[0]!.id = pageId;
  (document.pages[0]!.blocks as unknown[]).splice(3, 0, block('database', '', { page: { id: DATABASE } }));
  document.pages.push(
    page(DATABASE, 'Задачи', [], {
      parentId: pageId,
      database: {
        columns: ['Название', 'Статус', 'Срок'],
        rows: [
          { pageId: null, title: 'Сверстать страницу', icon: null, cells: ['Сверстать страницу', 'Готово', '24 октября 2026'] },
          { pageId: null, title: 'Проверить на телефоне', icon: null, cells: ['Проверить на телефоне', 'В работе', ''] },
        ],
      },
    }),
  );
  const published = await api('PUT', `/shares/${pageId}/document`, { digest: digestOf(document), document });
  expect(published.status).toBe(200);
  expect((await api('PUT', `/shares/${pageId}/files/${IMAGE}`, undefined, PNG_1x1)).status).toBeLessThan(300);
  return `${base}/s/${share.token}`;
}

test.beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), 'mynotion-e2e-'));
  const port = await freePort();
  base = `http://127.0.0.1:${port}`;
  const env = { ...process.env, DATA_DIR: dataDir, PORT: String(port), HOST: '127.0.0.1' };
  deviceToken = execFileSync(process.execPath, ['dist/cli.js', 'bootstrap', '--name', 'Mac', '--token-only'], { env }).toString().trim();
  server = spawn(process.execPath, ['dist/main.js'], { env, stdio: 'ignore' });
  await expect.poll(async () => (await fetch(`${base}/health`).catch(() => null))?.status, { timeout: 10_000 }).toBe(200);
});

test.afterAll(() => {
  server?.kill();
  rmSync(dataDir, { recursive: true, force: true });
});

test('страница по ссылке открывается без входа и выглядит как в приложении', async ({ browser }) => {
  const url = await publishedLink();
  mkdirSync(SCREENSHOTS, { recursive: true });
  for (const [name, options] of [
    ['desktop', { viewport: { width: 1280, height: 900 } }],
    ['phone', { ...devices['iPhone 14'], defaultBrowserType: undefined }],
  ] as const) {
    for (const colorScheme of ['light', 'dark'] as const) {
      const context = await browser.newContext({ ...options, colorScheme });
      const tab = await context.newPage();
      const response = await tab.goto(url);
      expect(response?.status()).toBe(200);
      expect(response?.headers()['x-robots-tag']).toContain('noindex');
      await expect(tab.locator('h1').first()).toContainText('Опубликованная страница');
      await expect(tab.getByRole('table').first()).toContainText('Сверстать страницу');
      await expect(tab.locator('img[src*="/files/"]').first()).toHaveJSProperty('complete', true);
      // Свёрнутый переключатель раскрывается щелчком, без скриптов.
      await expect(tab.getByText('Спрятано в списке')).toBeHidden();
      await tab.getByText('Раскрывающийся список').click();
      await expect(tab.getByText('Спрятано в списке')).toBeVisible();
      await tab.screenshot({ path: join(SCREENSHOTS, `share-${name}-${colorScheme}.png`), fullPage: name === 'phone' ? false : true });
      await context.close();
    }
  }
});

test('выключенная ссылка — 404 сразу, повторное включение — та же ссылка', async ({ page: tab }) => {
  const other = '0193a000-0000-7000-8000-0000000000aa';
  const url = await publishedLink(other);
  expect((await tab.goto(url))?.status()).toBe(200);
  expect((await api('PUT', `/shares/${other}`, { enabled: false })).status).toBe(200);
  const closed = await tab.goto(url);
  expect(closed?.status()).toBe(404);
  await expect(tab.locator('h1')).toHaveText('Ссылка не работает');
  const again = (await (await api('PUT', `/shares/${other}`, { enabled: true })).json()) as { token: string };
  expect(`${base}/s/${again.token}`).toBe(url);
});
