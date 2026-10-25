import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { beforeEach, describe, expect, it } from 'vitest';
import { openDatabase } from '../src/db.js';
import { createShares } from '../src/shares.js';
import { createTestServer, expectRussianError, joinDevice, makeTempDir, type TestServer } from './helpers.js';
import { block, CHILD, digestOf, documentOf, IMAGE, page, PDF, PNG_1x1, PRIVATE, richDocument, ROOT } from './share-fixtures.js';

interface Share {
  pageId: string;
  token: string;
  enabled: boolean;
  includeSubpages: boolean;
  digest: string | null;
  publishedAt: number | null;
}

async function enable(server: TestServer, pageId = ROOT, includeSubpages = true): Promise<Share> {
  const response = await server.call('PUT', `/shares/${pageId}`, { body: { enabled: true, includeSubpages } });
  expect(response.status).toBe(200);
  return (await response.json()) as Share;
}

async function publish(server: TestServer, document: unknown = richDocument(), pageId = ROOT) {
  return server.call('PUT', `/shares/${pageId}/document`, { body: { digest: digestOf(document), document } });
}

const putFile = (server: TestServer, fileId: string, body: Buffer, pageId = ROOT) =>
  server.call('PUT', `/shares/${pageId}/files/${fileId}`, { binary: new Uint8Array(body) });

const open = (server: TestServer, path: string) => server.call('GET', path, { token: null });

describe('ссылка: включение, выключение, смена', () => {
  let server: TestServer;
  beforeEach(() => {
    server = createTestServer();
  });

  it('без токена устройства управлять ссылками нельзя', async () => {
    for (const [method, path] of [
      ['GET', '/shares'],
      ['PUT', `/shares/${ROOT}`],
      ['PUT', `/shares/${ROOT}/document`],
    ] as const) {
      const response = await server.call(method, path, { token: null, body: method === 'GET' ? undefined : { enabled: true } });
      expect(response.status).toBe(401);
    }
  });

  it('первое включение создаёт длинную непредсказуемую ссылку', async () => {
    const share = await enable(server);
    expect(share.enabled).toBe(true);
    expect(share.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const other = await enable(server, CHILD);
    expect(other.token).not.toBe(share.token);
  });

  it('выключение — ссылка сразу 404, снимок стёрт; повторное включение — та же ссылка', async () => {
    const share = await enable(server);
    expect((await publish(server)).status).toBe(200);
    expect((await open(server, `/s/${share.token}`)).status).toBe(200);

    const off = await server.call('PUT', `/shares/${ROOT}`, { body: { enabled: false } });
    expect(off.status).toBe(200);
    expect(((await off.json()) as Share).digest).toBeNull();
    const closed = await open(server, `/s/${share.token}`);
    expect(closed.status).toBe(404);
    expect(await closed.text()).toContain('Ссылка не работает');

    const again = await enable(server);
    expect(again.token).toBe(share.token);
    expect(again.digest).toBeNull();
    expect((await open(server, `/s/${share.token}`)).status).toBe(404);
  });

  it('смена ссылки — старая сразу 404, новая открывает тот же снимок', async () => {
    const share = await enable(server);
    await publish(server);
    const rotated = await server.call('POST', `/shares/${ROOT}/rotate`);
    expect(rotated.status).toBe(200);
    const next = (await rotated.json()) as Share;
    expect(next.token).not.toBe(share.token);
    expect((await open(server, `/s/${share.token}`)).status).toBe(404);
    expect((await open(server, `/s/${next.token}`)).status).toBe(200);
  });

  it('список ссылок видят все устройства Юрия', async () => {
    const share = await enable(server);
    const other = await joinDevice(server, 'Второй Mac');
    const response = await server.call('GET', '/shares', { token: other.token });
    const { items } = (await response.json()) as { items: Share[] };
    expect(items).toEqual([expect.objectContaining({ pageId: ROOT, token: share.token, enabled: true })]);
  });

  it('удаление забывает ссылку', async () => {
    const share = await enable(server);
    await publish(server);
    expect((await server.call('DELETE', `/shares/${ROOT}`)).status).toBe(204);
    expect((await open(server, `/s/${share.token}`)).status).toBe(404);
    expect(((await (await server.call('GET', '/shares')).json()) as { items: Share[] }).items).toEqual([]);
  });

  it('id страницы — только UUID', async () => {
    const response = await server.call('PUT', '/shares/..%2Fetc', { body: { enabled: true } });
    expect(response.status).toBe(400);
    expectRussianError(await response.json(), 'bad_request');
  });
});

describe('снимок и файлы', () => {
  let server: TestServer;
  let token: string;
  beforeEach(async () => {
    server = createTestServer();
    token = (await enable(server)).token;
  });

  it('снимок выключенной ссылки не принимается', async () => {
    await server.call('PUT', `/shares/${ROOT}`, { body: { enabled: false } });
    const response = await publish(server);
    expect(response.status).toBe(409);
    expectRussianError(await response.json(), 'share_disabled');
  });

  it('снимок неизвестной страницы — 404', async () => {
    expect((await publish(server, richDocument(), CHILD)).status).toBe(404);
  });

  it('снимок другой страницы или кривой снимок — 400', async () => {
    const wrongRoot = documentOf([page(CHILD, 'Другая', [])], [], CHILD);
    expect((await publish(server, wrongRoot)).status).toBe(400);
    for (const broken of [{ version: 2 }, { version: 1, rootPageId: ROOT, pages: 'нет' }, null]) {
      const response = await server.call('PUT', `/shares/${ROOT}/document`, { body: { digest: 'x', document: broken } });
      expect(response.status).toBe(400);
    }
  });

  it('ответ на снимок перечисляет недостающие файлы; файл вне снимка не принимается', async () => {
    const answer = (await (await publish(server)).json()) as { missingFiles: string[] };
    expect(answer.missingFiles.sort()).toEqual([IMAGE, PDF].sort());
    expect((await putFile(server, IMAGE, PNG_1x1)).status).toBe(201);
    expect((await putFile(server, IMAGE, PNG_1x1)).status).toBe(200);
    const again = (await (await publish(server)).json()) as { missingFiles: string[] };
    expect(again.missingFiles).toEqual([PDF]);

    const stranger = await putFile(server, '0193a000-0000-7000-8000-0000000000aa', PNG_1x1);
    expect(stranger.status).toBe(409);
    expectRussianError(await stranger.json(), 'file_not_in_document');
  });

  it('файл не того размера, что в снимке, — 400', async () => {
    await publish(server);
    expect((await putFile(server, PDF, Buffer.from('слишком длинный файл'))).status).toBe(400);
  });

  it('файл отдаётся по ссылке; убранный из снимка — 404', async () => {
    await publish(server);
    await putFile(server, IMAGE, PNG_1x1);
    const file = await open(server, `/s/${token}/files/${IMAGE}`);
    expect(file.status).toBe(200);
    expect(file.headers.get('content-type')).toBe('image/png');
    expect(file.headers.get('x-content-type-options')).toBe('nosniff');
    expect(Buffer.from(await file.arrayBuffer()).equals(PNG_1x1)).toBe(true);

    await publish(server, documentOf([page(ROOT, 'Без картинки', [])]));
    expect((await open(server, `/s/${token}/files/${IMAGE}`)).status).toBe(404);
  });

  it('файл не картинка и не видео — скачивается, а не открывается в браузере', async () => {
    await publish(server);
    await putFile(server, PDF, Buffer.from('%PDF'));
    const file = await open(server, `/s/${token}/files/${PDF}`);
    expect(file.headers.get('content-disposition')).toMatch(/^attachment;/);
    expect(file.headers.get('content-disposition')).toContain("filename*=UTF-8''%D0%9E%D1%82%D1%87%D1%91%D1%82.pdf");
  });

  it('svg с картинкой-скриптом не открывается как страница', async () => {
    const svg = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>');
    const document = documentOf(
      [page(ROOT, 'SVG', [block('image', '', { props: { file: IMAGE } })])],
      [{ id: IMAGE, name: 'x.svg', mimeType: 'image/svg+xml', byteCount: svg.length }],
    );
    await publish(server, document);
    await putFile(server, IMAGE, svg);
    const file = await open(server, `/s/${token}/files/${IMAGE}`);
    expect(file.headers.get('content-disposition')).toMatch(/^attachment;/);
    expect(file.headers.get('content-security-policy')).toContain("default-src 'none'");
  });

  it('выключение стирает файлы: после включения их снова нет', async () => {
    await publish(server);
    await putFile(server, IMAGE, PNG_1x1);
    await server.call('PUT', `/shares/${ROOT}`, { body: { enabled: false } });
    await enable(server);
    const answer = (await (await publish(server)).json()) as { missingFiles: string[] };
    expect(answer.missingFiles).toContain(IMAGE);
  });

  it('digest снимка виден в списке', async () => {
    const document = richDocument();
    await publish(server, document);
    const { items } = (await (await server.call('GET', '/shares')).json()) as { items: Share[] };
    expect(items[0]?.digest).toBe(digestOf(document));
    expect(items[0]?.publishedAt).toEqual(expect.any(Number));
  });
});

describe('открытая страница', () => {
  let server: TestServer;
  let token: string;
  beforeEach(async () => {
    server = createTestServer();
    token = (await enable(server)).token;
    await publish(server);
  });

  it('главная и подстраница из снимка открываются; страница не из снимка — 404', async () => {
    const root = await open(server, `/s/${token}`);
    expect(root.status).toBe(200);
    expect(root.headers.get('content-type')).toMatch(/^text\/html/);
    expect(await root.text()).toContain('Опубликованная страница');
    expect((await open(server, `/s/${token}/${CHILD}`)).status).toBe(200);
    expect((await open(server, `/s/${token}/${PRIVATE}`)).status).toBe(404);
  });

  it('поисковики не индексируют, адрес не утекает через Referer, скриптов нет', async () => {
    const root = await open(server, `/s/${token}`);
    expect(root.headers.get('x-robots-tag')).toBe('noindex, nofollow');
    expect(root.headers.get('referrer-policy')).toBe('no-referrer');
    expect(root.headers.get('cache-control')).toBe('no-store');
    expect(root.headers.get('content-security-policy')).toContain("script-src 'none'");
    expect(await root.text()).toContain('<meta name="robots" content="noindex, nofollow">');
    const robots = await open(server, '/robots.txt');
    expect(await robots.text()).toContain('Disallow: /');
  });

  it('неизвестная ссылка — та же 404, что и выключенная', async () => {
    const unknown = await open(server, `/s/${'A'.repeat(43)}`);
    expect(unknown.status).toBe(404);
    expect(unknown.headers.get('x-robots-tag')).toBe('noindex, nofollow');
    expect(await unknown.text()).toContain('Ссылка не работает');
  });

  it('стили открываются без входа', async () => {
    const css = await open(server, '/share-assets/share.css');
    expect(css.status).toBe(200);
    expect(css.headers.get('content-type')).toMatch(/^text\/css/);
  });
});

describe('видео по частям, место и служебные ответы', () => {
  let server: TestServer;
  let token: string;
  const VIDEO = '0193a000-0000-7000-8000-0000000000f3';
  const clip = Buffer.from(Array.from({ length: 100 }, (_, index) => index));
  const videoDocument = () =>
    documentOf(
      [page(ROOT, 'Видео', [block('video', '', { props: { videoSource: 'file', file: VIDEO } })])],
      [{ id: VIDEO, name: 'clip.mp4', mimeType: 'video/mp4', byteCount: clip.length }],
    );
  beforeEach(async () => {
    server = createTestServer();
    token = (await enable(server)).token;
  });

  it('видео отдаётся по частям: 206 с Content-Range, неверный диапазон — 416', async () => {
    await publish(server, videoDocument());
    await putFile(server, VIDEO, clip);
    const whole = await open(server, `/s/${token}/files/${VIDEO}`);
    expect(whole.status).toBe(200);
    expect(whole.headers.get('accept-ranges')).toBe('bytes');

    const part = await server.call('GET', `/s/${token}/files/${VIDEO}`, { token: null, headers: { range: 'bytes=10-19' } });
    expect(part.status).toBe(206);
    expect(part.headers.get('content-range')).toBe('bytes 10-19/100');
    expect(part.headers.get('content-length')).toBe('10');
    expect([...Buffer.from(await part.arrayBuffer())]).toEqual([10, 11, 12, 13, 14, 15, 16, 17, 18, 19]);

    const tail = await server.call('GET', `/s/${token}/files/${VIDEO}`, { token: null, headers: { range: 'bytes=-5' } });
    expect(tail.headers.get('content-range')).toBe('bytes 95-99/100');
    const open_ = await server.call('GET', `/s/${token}/files/${VIDEO}`, { token: null, headers: { range: 'bytes=90-' } });
    expect(open_.headers.get('content-range')).toBe('bytes 90-99/100');

    const bad = await server.call('GET', `/s/${token}/files/${VIDEO}`, { token: null, headers: { range: 'bytes=200-300' } });
    expect(bad.status).toBe(416);
    expect(bad.headers.get('content-range')).toBe('bytes */100');
  });

  it('параллельные загрузки не превышают лимит места', async () => {
    const SECOND = '0193a000-0000-7000-8000-0000000000f4';
    const document = documentOf(
      [page(ROOT, 'Два видео', [block('video', '', { props: { videoSource: 'file', file: VIDEO } }), block('video', '', { props: { videoSource: 'file', file: SECOND } })])],
      [
        { id: VIDEO, name: 'a.mp4', mimeType: 'video/mp4', byteCount: clip.length },
        { id: SECOND, name: 'b.mp4', mimeType: 'video/mp4', byteCount: clip.length },
      ],
    );
    server = createTestServer(undefined, { sharesLimitBytes: Buffer.byteLength(JSON.stringify(document)) + 150 });
    token = (await enable(server)).token;
    await publish(server, document);
    const results = await Promise.all([putFile(server, VIDEO, clip), putFile(server, SECOND, clip)]);
    expect(results.map((response) => response.status).sort()).toEqual([201, 507]);
  });

  it('снимок тоже считается в месте: большой снимок сверх лимита — 507', async () => {
    server = createTestServer(undefined, { sharesLimitBytes: 1000 });
    await enable(server);
    const response = await publish(server);
    expect(response.status).toBe(507);
    expectRussianError(await response.json(), 'storage_full');
  });

  it('файл с тем же id, но другого размера, просится заново', async () => {
    await publish(server, videoDocument());
    await putFile(server, VIDEO, clip);
    const shorter = clip.subarray(0, 50);
    const changed = documentOf(
      [page(ROOT, 'Видео', [block('video', '', { props: { videoSource: 'file', file: VIDEO } })])],
      [{ id: VIDEO, name: 'clip.mp4', mimeType: 'video/mp4', byteCount: shorter.length }],
    );
    const answer = (await (await publish(server, changed)).json()) as { missingFiles: string[] };
    expect(answer.missingFiles).toEqual([VIDEO]);
    expect((await putFile(server, VIDEO, Buffer.from(shorter))).status).toBe(201);
    const file = await open(server, `/s/${token}/files/${VIDEO}`);
    expect(file.headers.get('content-length')).toBe('50');
  });

  it('выключение затирает снимок в файле базы, а не только помечает удалённым', async () => {
    const dir = makeTempDir();
    const db = openDatabase(join(dir, 'sync.db'));
    const shares = createShares(db, { dir: join(dir, 'shares'), limitBytes: 1024 ** 3 });
    shares.setEnabled(ROOT, true);
    const document = documentOf([page(ROOT, 'Тайная-заметка-для-проверки', [block('paragraph', 'секретный-абзац-'.repeat(400))])]);
    shares.publish(ROOT, digestOf(document), document);
    shares.setEnabled(ROOT, false);
    db.close();
    for (const name of readdirSync(dir).filter((file) => file.startsWith('sync.db'))) {
      expect(readFileSync(join(dir, name)).includes(Buffer.from('Тайная-заметка-для-проверки'))).toBe(false);
    }
  });

  it('служебные адреса ссылок отвечают страницей 404 с теми же заголовками', async () => {
    for (const path of ['/s', '/share-assets/нет.css']) {
      const response = await open(server, path);
      expect(response.status).toBe(404);
      expect(response.headers.get('x-robots-tag')).toBe('noindex, nofollow');
      expect(await response.text()).toContain('Ссылка не работает');
    }
  });

  it('формулы рисуются на сервере, стили формул открываются без входа', async () => {
    await publish(server);
    const html = await (await open(server, `/s/${token}`)).text();
    expect(html).toContain('class="katex');
    expect(html).toContain('<math');
    const css = await open(server, '/share-assets/katex/katex.min.css');
    expect(css.status).toBe(200);
    const font = /url\((fonts\/KaTeX_Main-Regular\.woff2)\)/.exec(await css.text());
    expect(font).not.toBeNull();
    const fontResponse = await open(server, `/share-assets/katex/${font![1]}`);
    expect(fontResponse.status).toBe(200);
    expect(fontResponse.headers.get('content-type')).toBe('font/woff2');
  });

  it('повторный показ страницы берётся из готового HTML, но со своей ссылкой', async () => {
    await publish(server);
    const first = await (await open(server, `/s/${token}`)).text();
    const rotated = (await (await server.call('POST', `/shares/${ROOT}/rotate`)).json()) as Share;
    const second = await (await open(server, `/s/${rotated.token}`)).text();
    expect(second).not.toContain(token);
    expect(second.replaceAll(rotated.token, token)).toBe(first);
  });
});
