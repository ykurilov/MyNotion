import { describe, expect, it } from 'vitest';
import { parseSharedDocument } from '../src/share-document.js';
import { renderSharedPage } from '../src/share-render.js';
import { block, CHILD, documentOf, IMAGE, page, PRIVATE, richDocument, ROOT } from './share-fixtures.js';

const TOKEN = 'T'.repeat(43);

function render(raw: unknown, pageId = ROOT, availableFiles: string[] = [IMAGE]): string {
  const document = parseSharedDocument(raw, ROOT);
  const html = renderSharedPage(document, pageId, { token: TOKEN, availableFiles: new Set(availableFiles) });
  if (html === null) throw new Error('страница не отрисована');
  return html;
}

const one = (...blocks: Record<string, unknown>[]) => documentOf([page(ROOT, 'Страница', blocks)]);

describe('отрисовка опубликованной страницы', () => {
  it('заголовок, иконка и язык страницы', () => {
    const html = render(richDocument());
    expect(html).toContain('<title>Опубликованная страница</title>');
    expect(html).toContain('<html lang="ru">');
    expect(html).toContain('🚀');
    expect(html).toMatch(/<h1 class="block heading1" id="h-[^"]+">Большой заголовок<\/h1>/);
  });

  it('текст экранируется: разметка из заметок не становится кодом', () => {
    const html = render(one(block('paragraph', '<script>alert(1)</script> & "кавычки"')));
    expect(html).not.toContain('<script>alert');
    expect(html).toContain('&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;кавычки&quot;');
  });

  it('оформление в строке: жирный, курсив, ссылка наружу без передачи адреса', () => {
    const html = render(richDocument());
    expect(html).toContain('<strong>Жирный</strong>');
    expect(html).toContain('<em>курсив</em>');
    expect(html).toContain('<a href="https://example.com/" rel="noopener noreferrer nofollow" target="_blank">ссылка</a>');
  });

  it('ссылка javascript: и другие опасные адреса не становятся ссылкой', () => {
    const text = { string: 'нажми', runs: [{ start: 0, length: 5, style: 'link', url: 'javascript:alert(1)' }] };
    const html = render(one(block('paragraph', 'нажми', { text })));
    expect(html).not.toContain('javascript:');
    expect(html).toContain('нажми');
  });

  it('упоминание опубликованной страницы — ссылка внутри ссылки; закрытой — «Нет доступа» без названия', () => {
    const html = render(richDocument());
    expect(html).toContain(`href="/s/${TOKEN}/${CHILD}"`);
    expect(html).toContain('Нет доступа');
    expect(html).not.toContain(PRIVATE);
  });

  it('упоминание страницы, которой нет в снимке, тоже закрыто, даже если в нём есть id', () => {
    const text = {
      string: '￼',
      runs: [{ start: 0, length: 1, style: 'mention', pageId: PRIVATE, title: 'Секрет', icon: null }],
    };
    const html = render(one(block('paragraph', '￼', { text })));
    expect(html).not.toContain('Секрет');
    expect(html).toContain('Нет доступа');
  });

  it('списки: маркированный с вложенным пунктом, нумерованный, задачи', () => {
    const html = render(richDocument());
    expect(html).toMatch(/<ul class="bulleted">\s*<li>Пункт списка<ul class="bulleted">\s*<li>Вложенный пункт<\/li>/);
    expect(html).toMatch(/<ol class="numbered">\s*<li>Первый<\/li>\s*<li>Второй<\/li>\s*<\/ol>/);
    expect(html).toContain('class="todo checked"');
  });

  it('раскрывающийся список и свёрнутый заголовок раскрываются кликом', () => {
    const html = render(richDocument());
    expect(html).toMatch(/<details class="block toggle">\s*<summary>Раскрывающийся список<\/summary>[\s\S]*Спрятано в списке[\s\S]*<\/details>/);
    expect(html).toMatch(/<details class="block heading-fold">\s*<summary><h2 class="heading2" id="h-[^"]+">Свёрнутый раздел<\/h2><\/summary>[\s\S]*Текст под свёрнутым заголовком[\s\S]*<\/details>/);
    // следующий заголовок того же уровня — уже вне свёрнутого раздела
    expect(html).toMatch(/<\/details>\s*<h2 class="block heading2" id="h-[^"]+">Следующий раздел<\/h2>/);
  });

  it('раскрытый переключатель открыт', () => {
    const html = render(one(block('toggle', 'Открыт'), block('paragraph', 'Внутри', { indent: 1 })));
    expect(html).toContain('<details class="block toggle" open>');
  });

  it('цитата, выноска, код, формула, разделитель', () => {
    const html = render(richDocument());
    expect(html).toContain('<blockquote class="block quote">Цитата');
    expect(html).toContain('class="block callout bg-gray"');
    expect(html).toContain('<pre class="block code" data-language="swift"><code>let x = 1 &lt; 2</code></pre>');
    expect(html).toContain('E = mc^2');
    expect(html).toContain('<hr class="block divider">');
  });

  it('картинка из снимка — по адресу ссылки; ещё не загруженная — заглушка', () => {
    expect(render(richDocument())).toContain(`<img src="/s/${TOKEN}/files/${IMAGE}"`);
    expect(render(richDocument(), ROOT, [])).toContain('Файл ещё не загружен');
  });

  it('файл, закладка и видео', () => {
    const html = render(richDocument(), ROOT, [IMAGE, '0193a000-0000-7000-8000-0000000000f2']);
    expect(html).toContain('Отчёт.pdf');
    expect(html).toContain('href="https://example.com/article"');
    expect(html).toContain('Описание статьи');
    expect(html).toContain('href="https://www.youtube.com/watch?v=dQw4w9WgXcQ"');
  });

  it('подстраница — ссылка; закрытая подстраница — «Нет доступа»', () => {
    const html = render(richDocument());
    expect(html).toMatch(new RegExp(`<a class="block page-link" href="/s/${TOKEN}/${CHILD}">`));
    expect(html.match(/Нет доступа/g)?.length).toBeGreaterThanOrEqual(2);
  });

  it('колонки и таблица', () => {
    const html = render(richDocument());
    expect(html).toMatch(/<div class="block columns">\s*<div class="column" style="flex: 0.5 1 0">[\s\S]*Левая колонка/);
    expect(html).toMatch(/<table class="block table">[\s\S]*<th>Имя<\/th>\s*<th>Возраст<\/th>[\s\S]*<td>Аня<\/td>\s*<td>7<\/td>/);
  });

  it('оглавление собирает заголовки страницы со ссылками на них', () => {
    const html = render(richDocument());
    expect(html).toMatch(/<nav class="block toc">[\s\S]*href="#h-[^"]+"[\s\S]*Большой заголовок/);
  });

  it('база — таблицей; строка из снимка открывается, строка вне его — без ссылки', () => {
    const database = page(CHILD, 'Задачи', [], {
      parentId: ROOT,
      database: {
        columns: ['Название', 'Статус'],
        rows: [
          { pageId: CHILD, title: 'Открытая строка', icon: null, cells: ['Открытая строка', 'Готово'] },
          { pageId: null, title: 'Закрытая строка', icon: null, cells: ['Закрытая строка', 'В работе'] },
        ],
      },
    });
    const html = render(documentOf([page(ROOT, 'Страница', [block('database', '', { page: { id: CHILD, title: 'Задачи', icon: null } })]), database]));
    expect(html).toMatch(/<table class="database">[\s\S]*<th>Статус<\/th>[\s\S]*Готово/);
    expect(html).toContain(`href="/s/${TOKEN}/${CHILD}"`);
    expect(html).toMatch(/<td>Закрытая строка<\/td>/);
  });

  it('у подстраницы — путь от опубликованной страницы', () => {
    const html = render(richDocument(), CHILD);
    expect(html).toMatch(new RegExp(`<nav class="breadcrumbs"><a href="/s/${TOKEN}">🚀 Опубликованная страница</a>`));
  });

  it('страницы нет в снимке — null', () => {
    const document = parseSharedDocument(richDocument(), ROOT);
    expect(renderSharedPage(document, PRIVATE, { token: TOKEN, availableFiles: new Set() })).toBeNull();
  });

  it('цвет и обложка — только из своего списка, стиль снаружи не подставляется', () => {
    const html = render(
      documentOf([
        page(ROOT, 'Цвета', [block('paragraph', 'x', { color: { text: 'red;background:url(x)' } })], {
          cover: { colors: ['#eb5757', 'red;}</style>'], side: 1, offset: 0.5 },
        }),
      ]),
    );
    expect(html).not.toContain('url(x)');
    expect(html).not.toContain('</style>');
  });

  it('формула — разметкой KaTeX без скриптов; строчная формула в тексте; ошибка — исходником', () => {
    const inline = block('paragraph', 'Масса ￼ тут', {
      text: { string: 'Масса ￼ тут', runs: [{ start: 6, length: 1, style: 'equation', latex: 'm_0' }] },
    });
    const html = render(one(block('equation', '\\frac{a}{b}'), inline, block('equation', '\\href{javascript:alert(1)}{x}'), block('equation', '\\frac{')));
    expect(html).toMatch(/<div class="block equation">.*class="katex-display"/s);
    expect(html).toContain('<span class="katex"><span class="katex-mathml"><math');
    // \\href без trust — не ссылка: адрес остаётся только текстом исходника формулы
    expect(html).not.toMatch(/href="javascript/i);
    expect(html).toContain('/share-assets/katex/katex.min.css');
    expect(render(one(block('paragraph', 'без формул')))).not.toContain('katex.min.css');
  });

  it('много блоков в одной таблице и много пробегов в строке рисуются быстро', () => {
    const table = block('table');
    const column = block('tableColumn', '', { container: table.id });
    const rows = Array.from({ length: 20_000 }, () => block('tableRow', '', { container: table.id }));
    const cells = rows.map((row) => block('tableCell', 'ячейка', { container: row.id, props: { columnId: column.id } }));
    const long = 'ж'.repeat(20_000);
    const runs = Array.from({ length: 10_000 }, (_, index) => ({ start: index * 2, length: 1, style: 'bold' }));
    const started = performance.now();
    render(one(table, column, ...rows, ...cells, block('paragraph', long, { text: { string: long, runs } })));
    expect(performance.now() - started).toBeLessThan(3000);
  });
});
