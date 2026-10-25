import { createHash } from 'node:crypto';

export const ROOT = '0193a000-0000-7000-8000-000000000001';
export const CHILD = '0193a000-0000-7000-8000-000000000002';
export const PRIVATE = '0193a000-0000-7000-8000-000000000099';
export const IMAGE = '0193a000-0000-7000-8000-0000000000f1';
export const PDF = '0193a000-0000-7000-8000-0000000000f2';

let counter = 0;
const blockId = () => `0193b000-0000-7000-8000-${String(++counter).padStart(12, '0')}`;

type Json = Record<string, unknown>;

export function block(kind: string, text = '', extra: Json = {}): Json {
  return { id: blockId(), kind, indent: 0, container: null, text: { string: text, runs: [] }, ...extra };
}

export function page(id: string, title: string, blocks: Json[], extra: Json = {}): Json {
  return { id, parentId: null, title, icon: null, cover: null, fullWidth: false, smallText: false, blocks, ...extra };
}

export function documentOf(pages: Json[], files: Json[] = [], rootPageId = ROOT): Json {
  return { version: 1, rootPageId, pages, files };
}

export const digestOf = (document: unknown) => createHash('sha256').update(JSON.stringify(document)).digest('hex');

/** Страница со всеми видами блоков: по ней проверяются отрисовка и браузерный тест. */
export function richDocument(): Json {
  const mentionRun = (start: number, pageId: string | null, title: string | null) => ({
    start,
    length: 1,
    style: 'mention',
    pageId,
    title,
    icon: null,
  });
  const columns = block('columnList');
  const left = block('column', '', { container: columns.id, props: { widthRatio: 0.5 } });
  const right = block('column', '', { container: columns.id, props: { widthRatio: 0.5 } });
  const table = block('table', '', { props: { hasHeaderRow: true } });
  const colA = block('tableColumn', '', { container: table.id });
  const colB = block('tableColumn', '', { container: table.id });
  const row1 = block('tableRow', '', { container: table.id });
  const row2 = block('tableRow', '', { container: table.id });
  const cell = (row: Json, column: Json, text: string) =>
    block('tableCell', text, { container: row.id, props: { columnId: column.id } });
  const folded = block('heading2', 'Свёрнутый раздел', { collapsed: true });
  const rootBlocks = [
    block('heading1', 'Большой заголовок'),
    block('paragraph', 'Жирный и курсив, ссылка', {
      text: {
        string: 'Жирный и курсив, ссылка',
        runs: [
          { start: 0, length: 6, style: 'bold' },
          { start: 9, length: 6, style: 'italic' },
          { start: 17, length: 6, style: 'link', url: 'https://example.com/' },
        ],
      },
    }),
    block('paragraph', 'См. ￼ и ￼', {
      text: { string: 'См. ￼ и ￼', runs: [mentionRun(4, CHILD, 'Подстраница'), mentionRun(8, null, null)] },
    }),
    block('bulletItem', 'Пункт списка'),
    block('bulletItem', 'Вложенный пункт', { indent: 1 }),
    block('numberedItem', 'Первый'),
    block('numberedItem', 'Второй'),
    block('checkbox', 'Сделано', { checked: true }),
    block('checkbox', 'Не сделано'),
    block('quote', 'Цитата'),
    block('callout', 'Выноска', { props: { icon: '💡' }, color: { background: 'gray' } }),
    block('code', 'let x = 1 < 2', { props: { language: 'swift' } }),
    block('equation', 'E = mc^2'),
    block('divider'),
    block('toggle', 'Раскрывающийся список', { collapsed: true }),
    block('paragraph', 'Спрятано в списке', { indent: 1 }),
    folded,
    block('paragraph', 'Текст под свёрнутым заголовком'),
    block('heading2', 'Следующий раздел'),
    block('image', '', { props: { file: IMAGE, width: 0.5, pixelSize: [2, 1] } }),
    block('file', '', { props: { file: PDF } }),
    block('bookmark', '', { props: { url: 'https://example.com/article', title: 'Статья', description: 'Описание статьи' } }),
    block('video', '', { props: { videoSource: 'youtube', url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ' } }),
    block('pageLink', '', { page: { id: CHILD, title: 'Подстраница', icon: '📄' } }),
    block('pageLink', '', { page: { id: null, title: null, icon: null } }),
    columns,
    left,
    right,
    block('paragraph', 'Левая колонка', { container: left.id }),
    block('paragraph', 'Правая колонка', { container: right.id }),
    table,
    colA,
    colB,
    row1,
    row2,
    cell(row1, colA, 'Имя'),
    cell(row1, colB, 'Возраст'),
    cell(row2, colA, 'Аня'),
    cell(row2, colB, '7'),
    block('tableOfContents'),
  ];
  return documentOf(
    [
      page(ROOT, 'Опубликованная страница', rootBlocks, { icon: '🚀', cover: { colors: ['#eb5757'], side: 1, offset: 0.5 } }),
      page(CHILD, 'Подстраница', [block('paragraph', 'Текст подстраницы')], { parentId: ROOT, icon: '📄' }),
    ],
    [
      { id: IMAGE, name: 'cat.png', mimeType: 'image/png', byteCount: PNG_1x1.length },
      { id: PDF, name: 'Отчёт.pdf', mimeType: 'application/pdf', byteCount: 4 },
    ],
  );
}

/** Картинка 1×1. */
export const PNG_1x1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);
