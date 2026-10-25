import type { InlineText, Run, SharedBlock, SharedDocument, SharedPage } from './share-document.js';

// Веб-страница из снимка: только HTML и CSS, без скриптов. Раскрытие — `<details>`, тема — по системе.
// Всё, что пришло из снимка, проходит через `escape`; адреса — через `safeUrl`; стили — только числа и цвета из списков.

export interface RenderOptions {
  token: string;
  /** Файлы снимка, которые уже лежат на сервере. */
  availableFiles: Set<string>;
}

export const STYLESHEET_PATH = '/share-assets/share.css';
const LOCKED = 'Нет доступа';

const escape = (text: string) =>
  text.replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]!);

const pageTitle = (page: SharedPage) => (page.title.trim() === '' ? 'Без названия' : page.title);

interface Context {
  document: SharedDocument;
  options: RenderOptions;
  page: SharedPage;
  /** Контейнер → его блоки по порядку. */
  flows: Map<string, SharedBlock[]>;
}

const pageUrl = (context: Context, pageId: string) =>
  pageId === context.document.rootPageId ? `/s/${context.options.token}` : `/s/${context.options.token}/${pageId}`;
const fileUrl = (context: Context, fileId: string) => `/s/${context.options.token}/files/${fileId}`;
const hasFile = (context: Context, fileId: string | undefined): fileId is string =>
  fileId !== undefined && context.document.files.has(fileId) && context.options.availableFiles.has(fileId);

/** Адрес наружу: только http(s), почта и телефон. */
function safeUrl(raw: string): string | null {
  try {
    const url = new URL(raw);
    return ['http:', 'https:', 'mailto:', 'tel:'].includes(url.protocol) ? url.href : null;
  } catch {
    return null;
  }
}

const external = (href: string, inner: string, className?: string) =>
  `<a${className ? ` class="${className}"` : ''} href="${escape(href)}" rel="noopener noreferrer nofollow" target="_blank">${inner}</a>`;

function colorClasses(color: SharedBlock['color']): string {
  return [color.text ? `c-${color.text}` : '', color.background ? `bg-${color.background}` : ''].filter(Boolean).join(' ');
}

const classes = (...names: string[]) => names.filter(Boolean).join(' ');

// MARK: Текст в строке

function renderMention(context: Context, run: Extract<Run, { style: 'mention' }>): string {
  const target = run.pageId ? context.document.pages.get(run.pageId) : undefined;
  if (!target) return `<span class="mention locked">🔒 ${LOCKED}</span>`;
  const icon = target.icon ? `<span class="mention-icon">${escape(target.icon)}</span>` : '';
  return `<a class="mention" href="${pageUrl(context, target.id)}">${icon}${escape(pageTitle(target))}</a>`;
}

function renderAtom(context: Context, run: Run): string | null {
  switch (run.style) {
    case 'mention':
      return renderMention(context, run);
    case 'date':
      return `<span class="date">${escape(run.text)}</span>`;
    case 'equation':
      return `<code class="equation">${escape(run.latex)}</code>`;
    default:
      return null;
  }
}

/** Ссылка на страницу MyNotion (`mynotion://page/<id>`) — внутрь снимка или текстом. */
function internalLink(context: Context, url: string): string | null | undefined {
  const match = /^mynotion:\/\/page\/([0-9a-f-]{36})$/i.exec(url);
  if (!match) return undefined;
  const id = match[1]!.toLowerCase();
  return context.document.pages.has(id) ? pageUrl(context, id) : null;
}

function renderInline(context: Context, text: InlineText): string {
  const { string, runs } = text;
  if (string.length === 0) return '';
  const cuts = new Set([0, string.length]);
  for (const run of runs) {
    cuts.add(run.start);
    cuts.add(run.start + run.length);
  }
  const points = [...cuts].filter((point) => point <= string.length).sort((a, b) => a - b);
  let html = '';
  for (let index = 0; index < points.length - 1; index += 1) {
    const start = points[index]!;
    const end = points[index + 1]!;
    const active = runs.filter((run) => run.start <= start && run.start + run.length >= end);
    const atom = active.find((run) => run.style === 'mention' || run.style === 'date' || run.style === 'equation');
    if (atom && end - start === 1 && string[start] === '￼') {
      html += renderAtom(context, atom) ?? '';
      continue;
    }
    let piece = escape(string.slice(start, end).replaceAll('￼', '')).replace(/\n/g, '<br>');
    if (piece === '') continue;
    const has = (style: string) => active.some((run) => run.style === style);
    if (has('code')) piece = `<code>${piece}</code>`;
    if (has('underline')) piece = `<u>${piece}</u>`;
    if (has('strikethrough')) piece = `<s>${piece}</s>`;
    if (has('italic')) piece = `<em>${piece}</em>`;
    if (has('bold')) piece = `<strong>${piece}</strong>`;
    const textColor = active.find((run) => run.style === 'textColor');
    const background = active.find((run) => run.style === 'backgroundColor');
    const colorClass = classes(
      textColor && 'color' in textColor ? `c-${textColor.color}` : '',
      background && 'color' in background ? `bg-${background.color}` : '',
    );
    if (colorClass) piece = `<span class="${colorClass}">${piece}</span>`;
    const link = active.find((run): run is Extract<Run, { style: 'link' }> => run.style === 'link');
    if (link) {
      const inside = internalLink(context, link.url);
      if (inside) piece = `<a href="${escape(inside)}">${piece}</a>`;
      else if (inside === undefined) {
        const href = safeUrl(link.url);
        if (href) piece = external(href, piece);
      }
    }
    html += piece;
  }
  return html;
}

// MARK: Блоки

interface Node {
  block: SharedBlock;
  children: Node[];
}

/** Поток блоков в дерево: дети — следующие блоки глубже (глубина уже урезана приложением). */
function tree(blocks: SharedBlock[]): Node[] {
  const nodes: Node[] = [];
  let index = 0;
  while (index < blocks.length) {
    const block = blocks[index]!;
    let end = index + 1;
    while (end < blocks.length && blocks[end]!.indent > block.indent) end += 1;
    nodes.push({ block, children: tree(blocks.slice(index + 1, end)) });
    index = end;
  }
  return nodes;
}

const headingLevel = (kind: string) => (kind === 'heading1' ? 1 : kind === 'heading2' ? 2 : kind === 'heading3' ? 3 : null);
const LIST_KINDS: Record<string, { tag: 'ul' | 'ol'; className: string }> = {
  bulletItem: { tag: 'ul', className: 'bulleted' },
  numberedItem: { tag: 'ol', className: 'numbered' },
  checkbox: { tag: 'ul', className: 'todos' },
};

function renderNodes(context: Context, nodes: Node[]): string {
  const parts: string[] = [];
  let index = 0;
  while (index < nodes.length) {
    const node = nodes[index]!;
    const list = LIST_KINDS[node.block.kind];
    if (list) {
      let end = index;
      while (end < nodes.length && nodes[end]!.block.kind === node.block.kind) end += 1;
      const items = nodes.slice(index, end).map((item) => renderListItem(context, item));
      parts.push(`<${list.tag} class="${list.className}">\n${items.join('\n')}\n</${list.tag}>`);
      index = end;
      continue;
    }
    const level = headingLevel(node.block.kind);
    if (level !== null && node.block.collapsed) {
      let end = index + 1;
      while (end < nodes.length) {
        const other = headingLevel(nodes[end]!.block.kind);
        if (other !== null && other <= level) break;
        end += 1;
      }
      const section = renderNodes(context, nodes.slice(index + 1, end));
      parts.push(
        `<details class="${classes('block heading-fold', colorClasses(node.block.color))}">\n<summary>${renderHeading(context, node.block, false)}</summary>\n${section}\n</details>`,
      );
      index = end;
      continue;
    }
    parts.push(renderBlock(context, node));
    index += 1;
  }
  return parts.filter((part) => part !== '').join('\n');
}

function renderListItem(context: Context, node: Node): string {
  const { block } = node;
  const text = renderInline(context, block.text);
  const children = node.children.length > 0 ? renderNodes(context, node.children) : '';
  const color = colorClasses(block.color);
  if (block.kind === 'checkbox') {
    return `<li class="${classes('todo', block.checked ? 'checked' : '', color)}"><span class="box" aria-hidden="true"></span><span class="todo-text">${text}</span>${children}</li>`;
  }
  return `<li${color ? ` class="${color}"` : ''}>${text}${children}</li>`;
}

function renderHeading(context: Context, block: SharedBlock, standalone: boolean): string {
  const level = headingLevel(block.kind)!;
  const className = standalone ? classes('block', block.kind, colorClasses(block.color)) : block.kind;
  return `<h${level} class="${className}" id="h-${block.id}">${renderInline(context, block.text)}</h${level}>`;
}

function renderBlock(context: Context, node: Node): string {
  const { block } = node;
  const text = () => renderInline(context, block.text);
  const children = () => (node.children.length > 0 ? `\n${renderNodes(context, node.children)}` : '');
  const color = colorClasses(block.color);
  switch (block.kind) {
    case 'paragraph':
      return block.text.string === '' && node.children.length === 0
        ? '<p class="block paragraph empty"></p>'
        : `<p class="${classes('block paragraph', color)}">${text()}</p>${children()}`;
    case 'heading1':
    case 'heading2':
    case 'heading3':
      return renderHeading(context, block, true) + children();
    case 'toggle':
      return `<details class="${classes('block toggle', color)}"${block.collapsed ? '' : ' open'}>\n<summary>${text()}</summary>${children()}\n</details>`;
    case 'quote':
      return `<blockquote class="${classes('block quote', color)}">${text()}${children()}</blockquote>`;
    case 'callout': {
      const icon = block.props.icon ?? '💡';
      return `<div class="${classes('block callout', color)}"><span class="callout-icon">${escape(icon)}</span><div class="callout-body">${text()}${children()}</div></div>`;
    }
    case 'divider':
      return '<hr class="block divider">';
    case 'code':
      return `<pre class="block code" data-language="${escape(block.props.language ?? 'plain')}"><code>${escape(block.text.string)}</code></pre>`;
    case 'equation':
      return `<div class="block equation"><code>${escape(block.text.string)}</code></div>`;
    case 'tableOfContents':
      return renderTableOfContents(context);
    case 'image':
      return renderImage(context, block);
    case 'file':
      return renderFile(context, block);
    case 'video':
      return renderVideo(context, block);
    case 'bookmark':
      return renderBookmark(context, block);
    case 'pageLink':
      return renderPageLink(context, block);
    case 'database':
      return renderDatabaseBlock(context, block);
    case 'columnList':
      return renderColumns(context, block);
    case 'table':
      return renderTable(context, block);
    default:
      // строки и ячейки таблиц, колонки — внутри своих контейнеров; неизвестное — текстом
      return block.text.string === '' ? '' : `<p class="block paragraph">${text()}</p>${children()}`;
  }
}

function missingFile(name?: string): string {
  const label = name ? `${escape(name)} — файл ещё не загружен` : 'Файл ещё не загружен';
  return `<div class="block missing-file">${label}</div>`;
}

function renderImage(context: Context, block: SharedBlock): string {
  const fileId = block.props.file;
  if (!hasFile(context, fileId)) return missingFile();
  const width = block.props.width && block.props.width < 1 ? ` style="width: ${Math.round(block.props.width * 1000) / 10}%"` : '';
  const size = block.props.pixelSize ? ` width="${Math.round(block.props.pixelSize[0])}" height="${Math.round(block.props.pixelSize[1])}"` : '';
  const caption = block.text.string ? `<figcaption>${renderInline(context, block.text)}</figcaption>` : '';
  return `<figure class="block image"${width}><img src="${fileUrl(context, fileId)}" alt=""${size} loading="lazy">${caption}</figure>`;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} Б`;
  if (bytes < 1024 ** 2) return `${Math.round(bytes / 1024)} КБ`;
  return `${(bytes / 1024 ** 2).toFixed(1).replace('.', ',')} МБ`;
}

function renderFile(context: Context, block: SharedBlock): string {
  const fileId = block.props.file;
  const file = fileId ? context.document.files.get(fileId) : undefined;
  if (!file) return missingFile();
  if (!hasFile(context, fileId)) return missingFile(file.name);
  return `<a class="block file" href="${fileUrl(context, fileId)}" download="${escape(file.name)}"><span class="file-icon">📎</span><span class="file-name">${escape(file.name)}</span><span class="file-size">${formatBytes(file.byteCount)}</span></a>`;
}

function renderVideo(context: Context, block: SharedBlock): string {
  const poster = hasFile(context, block.props.poster) ? fileUrl(context, block.props.poster) : null;
  if (block.props.videoSource === 'file' || (block.props.file && !block.props.url)) {
    if (!hasFile(context, block.props.file)) return missingFile();
    return `<video class="block video" controls preload="metadata" src="${fileUrl(context, block.props.file)}"${poster ? ` poster="${poster}"` : ''}></video>`;
  }
  const href = block.props.url ? safeUrl(block.props.url) : null;
  if (!href) return '';
  const site = block.props.videoSource === 'vimeo' ? 'Vimeo' : block.props.videoSource === 'youtube' ? 'YouTube' : 'сайте';
  const picture = poster ? `<img src="${poster}" alt="" loading="lazy">` : '';
  return external(href, `${picture}<span class="video-play">▶ Смотреть на ${site}</span>`, 'block video-link');
}

function renderBookmark(context: Context, block: SharedBlock): string {
  const href = block.props.url ? safeUrl(block.props.url) : null;
  if (!href) return '';
  const title = block.props.title || href;
  const description = block.props.description ? `<span class="bookmark-description">${escape(block.props.description)}</span>` : '';
  const icon = hasFile(context, block.props.iconFile) ? `<img class="bookmark-favicon" src="${fileUrl(context, block.props.iconFile)}" alt="">` : '';
  const image = hasFile(context, block.props.image) ? `<span class="bookmark-image"><img src="${fileUrl(context, block.props.image)}" alt="" loading="lazy"></span>` : '';
  return external(
    href,
    `<span class="bookmark-text"><span class="bookmark-title">${escape(title)}</span>${description}<span class="bookmark-url">${icon}${escape(href)}</span></span>${image}`,
    'block bookmark',
  );
}

function lockedPage(className: string): string {
  return `<div class="block ${className} locked"><span class="page-icon">🔒</span><span class="page-title-text">${LOCKED}</span></div>`;
}

function renderPageLink(context: Context, block: SharedBlock): string {
  const target = block.page?.id ? context.document.pages.get(block.page.id) : undefined;
  if (!target) return lockedPage('page-link');
  const icon = target.icon ?? (target.database ? '▦' : '📄');
  return `<a class="block page-link" href="${pageUrl(context, target.id)}"><span class="page-icon">${escape(icon)}</span><span class="page-title-text">${escape(pageTitle(target))}</span></a>`;
}

function renderDatabaseTable(context: Context, database: NonNullable<SharedPage['database']>): string {
  const head = database.columns.map((name) => `<th>${escape(name)}</th>`).join('');
  const rows = database.rows.map((row) => {
    const cells = database.columns.map((_, index) => {
      const value = row.cells[index] ?? '';
      if (index === 0 && row.pageId && context.document.pages.has(row.pageId)) {
        const icon = row.icon ? `${escape(row.icon)} ` : '';
        return `<td><a href="${pageUrl(context, row.pageId)}">${icon}${escape(value || 'Без названия')}</a></td>`;
      }
      return `<td>${escape(value)}</td>`;
    });
    return `<tr>${cells.join('')}</tr>`;
  });
  return `<div class="table-wrap"><table class="database"><thead><tr>${head}</tr></thead><tbody>\n${rows.join('\n')}\n</tbody></table></div>`;
}

function renderDatabaseBlock(context: Context, block: SharedBlock): string {
  const target = block.page?.id ? context.document.pages.get(block.page.id) : undefined;
  if (!target?.database) return lockedPage('database-block');
  return `<section class="block database-block"><h3 class="database-title">${escape(pageTitle(target))}</h3>${renderDatabaseTable(context, target.database)}</section>`;
}

function renderColumns(context: Context, block: SharedBlock): string {
  const columns = (context.flows.get(block.id) ?? []).filter((item) => item.kind === 'column');
  if (columns.length === 0) return '';
  const html = columns.map((column) => {
    const ratio = column.props.widthRatio && column.props.widthRatio > 0 ? column.props.widthRatio : 1 / columns.length;
    const flex = Math.round(ratio * 1000) / 1000;
    return `<div class="column" style="flex: ${flex} 1 0">\n${renderFlow(context, context.flows.get(column.id) ?? [])}\n</div>`;
  });
  return `<div class="block columns">\n${html.join('\n')}\n</div>`;
}

function renderTable(context: Context, block: SharedBlock): string {
  const items = context.flows.get(block.id) ?? [];
  const columns = items.filter((item) => item.kind === 'tableColumn');
  const rows = items.filter((item) => item.kind === 'tableRow');
  if (columns.length === 0 || rows.length === 0) return '';
  const colgroup = columns
    .map((column) => (column.props.width ? `<col style="width: ${Math.round(column.props.width)}px">` : '<col>'))
    .join('');
  const body = rows.map((row, rowIndex) => {
    const cells = new Map((context.flows.get(row.id) ?? []).filter((cell) => cell.props.columnId).map((cell) => [cell.props.columnId!, cell]));
    const html = columns.map((column, columnIndex) => {
      const cell = cells.get(column.id);
      const isHeader = (block.props.hasHeaderRow === true && rowIndex === 0) || (block.props.hasHeaderColumn === true && columnIndex === 0);
      const tag = isHeader ? 'th' : 'td';
      const color = cell ? colorClasses(cell.color) : '';
      return `<${tag}${color ? ` class="${color}"` : ''}>${cell ? renderInline(context, cell.text) : ''}</${tag}>`;
    });
    return `<tr>\n${html.join('\n')}\n</tr>`;
  });
  return `<div class="table-wrap"><table class="block table"><colgroup>${colgroup}</colgroup>\n${body.join('\n')}\n</table></div>`;
}

function renderTableOfContents(context: Context): string {
  const headings = context.page.blocks.filter((block) => headingLevel(block.kind) !== null && block.text.string.trim() !== '');
  if (headings.length === 0) return '';
  const links = headings.map(
    (block) => `<a class="toc-${headingLevel(block.kind)}" href="#h-${block.id}">${escape(block.text.string.replaceAll('￼', ''))}</a>`,
  );
  return `<nav class="block toc">\n${links.join('\n')}\n</nav>`;
}

function renderFlow(context: Context, blocks: SharedBlock[]): string {
  return renderNodes(context, tree(blocks));
}

// MARK: Страница

function renderCover(context: Context): string {
  const cover = context.page.cover;
  if (!cover) return '';
  const position = `${Math.round(cover.offset * 100)}%`;
  if ('file' in cover) {
    if (!hasFile(context, cover.file)) return '';
    return `<div class="cover"><img src="${fileUrl(context, cover.file)}" alt="" style="object-position: center ${position}"></div>`;
  }
  const cells = cover.colors.map((value) => `<i style="background: ${value}"></i>`).join('');
  return `<div class="cover cover-colors"><div class="cover-grid" style="grid-template-columns: repeat(${cover.side}, 1fr)">${cells}</div></div>`;
}

function renderBreadcrumbs(context: Context): string {
  const { document, page } = context;
  if (page.id === document.rootPageId) return '';
  const path: SharedPage[] = [];
  const seen = new Set<string>([page.id]);
  let parent = page.parentId ? document.pages.get(page.parentId) : undefined;
  while (parent && !seen.has(parent.id)) {
    path.unshift(parent);
    seen.add(parent.id);
    parent = parent.parentId ? document.pages.get(parent.parentId) : undefined;
  }
  const root = document.pages.get(document.rootPageId)!;
  if (path[0]?.id !== root.id) path.unshift(root);
  const label = (item: SharedPage) => escape([item.icon, pageTitle(item)].filter(Boolean).join(' '));
  const links = path.map((item) => `<a href="${pageUrl(context, item.id)}">${label(item)}</a>`);
  return `<nav class="breadcrumbs">${links.join('<span class="crumb-gap">/</span>')}<span class="crumb-gap">/</span><span>${label(page)}</span></nav>`;
}

function shell(title: string, body: string, bodyClass = ''): string {
  return `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<meta name="color-scheme" content="light dark">
<title>${escape(title)}</title>
<link rel="stylesheet" href="${STYLESHEET_PATH}">
</head>
<body${bodyClass ? ` class="${bodyClass}"` : ''}>
${body}
</body>
</html>
`;
}

/** Страница снимка; `null` — такой страницы в снимке нет. */
export function renderSharedPage(document: SharedDocument, pageId: string, options: RenderOptions): string | null {
  const page = document.pages.get(pageId);
  if (!page) return null;
  const ids = new Set(page.blocks.map((block) => block.id));
  const flows = new Map<string, SharedBlock[]>();
  const pageFlow: SharedBlock[] = [];
  const orphans: SharedBlock[] = [];
  for (const block of page.blocks) {
    if (block.container === null) pageFlow.push(block);
    else if (ids.has(block.container)) flows.set(block.container, [...(flows.get(block.container) ?? []), block]);
    else orphans.push({ ...block, container: null });
  }
  const context: Context = { document, options, page, flows };
  const icon = page.icon ? `<div class="page-icon-large">${escape(page.icon)}</div>` : '';
  const cover = renderCover(context);
  const content = renderFlow(context, [...pageFlow, ...orphans]);
  const database = page.database ? renderDatabaseTable(context, page.database) : '';
  const body = `${cover}
<main class="${classes('page', cover ? 'has-cover' : '', icon ? 'has-icon' : '')}">
${renderBreadcrumbs(context)}
<header class="page-header">${icon}<h1 class="page-title">${escape(pageTitle(page))}</h1></header>
<article class="page-body">
${content}
${database}
</article>
</main>`;
  return shell(pageTitle(page), body, classes(page.fullWidth ? 'full-width' : '', page.smallText ? 'small-text' : ''));
}

/** Одна и та же страница для неизвестной, выключенной и сменённой ссылки: по ней не понять, была ли ссылка. */
export function renderNotFoundPage(): string {
  return shell(
    'Ссылка не работает',
    `<main class="page not-found"><div class="page-icon-large">🔒</div><h1 class="page-title">Ссылка не работает</h1><p>Владелец закрыл доступ к этой странице или сменил ссылку.</p></main>`,
  );
}
