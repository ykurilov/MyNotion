import { ApiError } from './errors.js';

// Снимок опубликованной страницы (specs/006-share-link/contracts/share-api.md). Приложение уже убрало всё закрытое;
// здесь — проверка формы и чистка: в отрисовку попадают только известные поля и значения из своих списков.

export const MAX_DOCUMENT_BYTES = 20 * 1024 * 1024;
const MAX_PAGES = 5000;
const MAX_BLOCKS = 200_000;

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HEX_COLOR = /^#[0-9a-f]{6}$/i;
const COLORS = new Set(['gray', 'brown', 'orange', 'yellow', 'green', 'blue', 'purple', 'pink', 'red']);
const FLAG_STYLES = new Set(['bold', 'italic', 'strikethrough', 'code', 'underline']);
const BLOCK_KINDS = new Set([
  'paragraph', 'heading1', 'heading2', 'heading3', 'bulletItem', 'numberedItem', 'checkbox', 'pageLink', 'toggle',
  'quote', 'callout', 'divider', 'code', 'equation', 'tableOfContents', 'image', 'file', 'video', 'bookmark', 'table',
  'tableRow', 'tableColumn', 'tableCell', 'columnList', 'column', 'database',
]);

export type NotionColor = 'gray' | 'brown' | 'orange' | 'yellow' | 'green' | 'blue' | 'purple' | 'pink' | 'red';

export type Run =
  | { start: number; length: number; style: 'bold' | 'italic' | 'strikethrough' | 'code' | 'underline' }
  | { start: number; length: number; style: 'link'; url: string }
  | { start: number; length: number; style: 'textColor' | 'backgroundColor'; color: NotionColor }
  | { start: number; length: number; style: 'mention'; pageId: string | null; title: string | null; icon: string | null }
  | { start: number; length: number; style: 'date'; text: string }
  | { start: number; length: number; style: 'equation'; latex: string };

export interface InlineText {
  string: string;
  runs: Run[];
}

export interface PageRef {
  id: string | null;
  title: string | null;
  icon: string | null;
}

export interface BlockProps {
  icon?: string;
  language?: string;
  width?: number;
  pixelSize?: [number, number];
  url?: string;
  title?: string;
  description?: string;
  hasHeaderRow?: boolean;
  hasHeaderColumn?: boolean;
  columnId?: string;
  widthRatio?: number;
  videoSource?: string;
  file?: string;
  poster?: string;
  image?: string;
  iconFile?: string;
}

export interface SharedBlock {
  id: string;
  kind: string;
  indent: number;
  container: string | null;
  text: InlineText;
  checked: boolean;
  collapsed: boolean;
  color: { text?: NotionColor; background?: NotionColor };
  props: BlockProps;
  page?: PageRef;
}

export type Cover = { file: string; offset: number } | { colors: string[]; side: number; offset: number };

export interface SharedDatabase {
  columns: string[];
  rows: { pageId: string | null; title: string; icon: string | null; cells: string[] }[];
}

export interface SharedPage {
  id: string;
  parentId: string | null;
  title: string;
  icon: string | null;
  cover: Cover | null;
  fullWidth: boolean;
  smallText: boolean;
  blocks: SharedBlock[];
  database?: SharedDatabase;
}

export interface SharedFile {
  id: string;
  name: string;
  mimeType: string;
  byteCount: number;
}

export interface SharedDocument {
  version: 1;
  rootPageId: string;
  pages: Map<string, SharedPage>;
  files: Map<string, SharedFile>;
}

const invalid = (message: string) => new ApiError(400, 'bad_request', `Снимок страницы: ${message}`);

type Obj = Record<string, unknown>;
const isObject = (value: unknown): value is Obj => typeof value === 'object' && value !== null && !Array.isArray(value);
const str = (value: unknown, fallback = ''): string => (typeof value === 'string' ? value : fallback);
const optStr = (value: unknown): string | undefined => (typeof value === 'string' ? value : undefined);
const nullableStr = (value: unknown): string | null => (typeof value === 'string' ? value : null);
const num = (value: unknown): number | undefined => (typeof value === 'number' && Number.isFinite(value) ? value : undefined);
const uuid = (value: unknown): string | null => (typeof value === 'string' && UUID.test(value) ? value : null);
const color = (value: unknown): NotionColor | undefined => (typeof value === 'string' && COLORS.has(value) ? (value as NotionColor) : undefined);

function parseRuns(raw: unknown, length: number): Run[] {
  if (!Array.isArray(raw)) return [];
  const runs: Run[] = [];
  for (const item of raw) {
    if (!isObject(item)) continue;
    const start = num(item.start);
    const runLength = num(item.length);
    if (start === undefined || runLength === undefined || start < 0 || runLength <= 0 || start + runLength > length) continue;
    const base = { start: Math.floor(start), length: Math.floor(runLength) };
    const style = item.style;
    if (typeof style === 'string' && FLAG_STYLES.has(style)) runs.push({ ...base, style: style as 'bold' });
    else if (style === 'link' && typeof item.url === 'string') runs.push({ ...base, style, url: item.url });
    else if ((style === 'textColor' || style === 'backgroundColor') && color(item.color)) {
      runs.push({ ...base, style, color: color(item.color)! });
    } else if (style === 'mention') {
      runs.push({ ...base, style, pageId: uuid(item.pageId), title: nullableStr(item.title), icon: nullableStr(item.icon) });
    } else if (style === 'date') runs.push({ ...base, style, text: str(item.text) });
    else if (style === 'equation') runs.push({ ...base, style, latex: str(item.latex) });
  }
  return runs;
}

function parseText(raw: unknown): InlineText {
  if (!isObject(raw)) return { string: '', runs: [] };
  const string = str(raw.string);
  return { string, runs: parseRuns(raw.runs, string.length) };
}

function parseProps(raw: unknown): BlockProps {
  if (!isObject(raw)) return {};
  const props: BlockProps = {};
  for (const key of ['icon', 'language', 'url', 'title', 'description', 'videoSource'] as const) {
    const value = optStr(raw[key]);
    if (value !== undefined) props[key] = value;
  }
  for (const key of ['width', 'widthRatio'] as const) {
    const value = num(raw[key]);
    if (value !== undefined) props[key] = value;
  }
  for (const key of ['hasHeaderRow', 'hasHeaderColumn'] as const) {
    if (typeof raw[key] === 'boolean') props[key] = raw[key];
  }
  for (const key of ['columnId', 'file', 'poster', 'image', 'iconFile'] as const) {
    const value = uuid(raw[key]);
    if (value) props[key] = value;
  }
  if (Array.isArray(raw.pixelSize) && raw.pixelSize.length === 2) {
    const [width, height] = raw.pixelSize.map(num);
    if (width && height && width > 0 && height > 0) props.pixelSize = [width, height];
  }
  return props;
}

function parseBlock(raw: unknown): SharedBlock | null {
  if (!isObject(raw)) return null;
  const id = uuid(raw.id);
  if (!id || typeof raw.kind !== 'string' || !BLOCK_KINDS.has(raw.kind)) return null;
  const block: SharedBlock = {
    id,
    kind: raw.kind,
    indent: Math.min(Math.max(Math.floor(num(raw.indent) ?? 0), 0), 8),
    container: uuid(raw.container),
    text: parseText(raw.text),
    checked: raw.checked === true,
    collapsed: raw.collapsed === true,
    color: isObject(raw.color) ? { text: color(raw.color.text), background: color(raw.color.background) } : {},
    props: parseProps(raw.props),
  };
  if (isObject(raw.page)) block.page = { id: uuid(raw.page.id), title: nullableStr(raw.page.title), icon: nullableStr(raw.page.icon) };
  return block;
}

function parseCover(raw: unknown): Cover | null {
  if (!isObject(raw)) return null;
  const offset = Math.min(Math.max(num(raw.offset) ?? 0.5, 0), 1);
  const file = uuid(raw.file);
  if (file) return { file, offset };
  if (Array.isArray(raw.colors)) {
    const colors = raw.colors.filter((value): value is string => typeof value === 'string' && HEX_COLOR.test(value));
    const side = Math.floor(num(raw.side) ?? 1);
    if (colors.length > 0 && side >= 1 && side * side === colors.length) return { colors, side, offset };
    if (colors.length > 0) return { colors: [colors[0]!], side: 1, offset };
  }
  return null;
}

function parseDatabase(raw: unknown): SharedDatabase | undefined {
  if (!isObject(raw) || !Array.isArray(raw.columns) || !Array.isArray(raw.rows)) return undefined;
  const columns = raw.columns.map((value) => str(value));
  const rows = raw.rows.filter(isObject).map((row) => ({
    pageId: uuid(row.pageId),
    title: str(row.title),
    icon: nullableStr(row.icon),
    cells: Array.isArray(row.cells) ? row.cells.map((value) => str(value)) : [],
  }));
  return { columns, rows };
}

/** Проверяет снимок для страницы `rootPageId`; ошибка формы — `400 bad_request`. */
export function parseSharedDocument(raw: unknown, rootPageId: string): SharedDocument {
  if (!isObject(raw) || raw.version !== 1) throw invalid('нужна версия 1');
  if (raw.rootPageId !== rootPageId) throw invalid('снимок другой страницы');
  if (!Array.isArray(raw.pages) || raw.pages.length === 0 || raw.pages.length > MAX_PAGES) throw invalid('нет страниц');
  const pages = new Map<string, SharedPage>();
  let blockCount = 0;
  for (const item of raw.pages) {
    if (!isObject(item)) throw invalid('страница должна быть объектом');
    const id = uuid(item.id);
    if (!id) throw invalid('id страницы должен быть UUID');
    if (!Array.isArray(item.blocks)) throw invalid('у страницы нет списка блоков');
    blockCount += item.blocks.length;
    if (blockCount > MAX_BLOCKS) throw invalid('слишком много блоков');
    pages.set(id, {
      id,
      parentId: uuid(item.parentId),
      title: str(item.title),
      icon: nullableStr(item.icon),
      cover: parseCover(item.cover),
      fullWidth: item.fullWidth === true,
      smallText: item.smallText === true,
      blocks: item.blocks.map(parseBlock).filter((block): block is SharedBlock => block !== null),
      database: parseDatabase(item.database),
    });
  }
  if (!pages.has(rootPageId)) throw invalid('нет самой опубликованной страницы');
  const files = new Map<string, SharedFile>();
  if (Array.isArray(raw.files)) {
    for (const item of raw.files) {
      if (!isObject(item)) continue;
      const id = uuid(item.id);
      const byteCount = num(item.byteCount);
      if (!id || byteCount === undefined || byteCount < 0) continue;
      files.set(id, { id, name: str(item.name, 'файл'), mimeType: str(item.mimeType, 'application/octet-stream'), byteCount });
    }
  }
  return { version: 1, rootPageId, pages, files };
}
