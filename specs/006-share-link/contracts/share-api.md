# Доступ по ссылке: API сервера и снимок страницы

Сервер синхронизации хранит записи зашифрованными и содержимого страниц не видит. Поэтому опубликованную страницу
приложение собирает само — очищенный снимок (только то, что видно по ссылке) — и отправляет его серверу открытым
текстом. Сервер рисует из снимка веб-страницу. Зашифрованный журнал и файлы синхронизации публикация не трогает.

## Запросы приложения (токен устройства, `Authorization: Bearer …`)

| Запрос | Что делает |
|---|---|
| `GET /shares` | `{items: Share[]}` — все страницы со ссылкой (в том числе выключенные). |
| `PUT /shares/{pageId}` `{enabled, includeSubpages?}` | Включить или выключить. Первое включение создаёт ссылку. Выключение сразу стирает снимок и файлы; ссылка запоминается, и повторное включение возвращает её же. `200 Share`. |
| `POST /shares/{pageId}/rotate` | Новая ссылка; старая сразу перестаёт открываться. `200 Share`, нет — `404`. |
| `DELETE /shares/{pageId}` | Забыть совсем (страница стёрта). `204`. |
| `PUT /shares/{pageId}/document` `{digest, document}` | Новый снимок (≤ 20 МБ). `200 {missingFiles: id[]}` — каких файлов снимка ещё нет. Файлы, которых в снимке больше нет, стираются. Выключена — `409 share_disabled`. |
| `PUT /shares/{pageId}/files/{fileId}` (тело — байты файла) | Файл из снимка, открытым текстом, ≤ 100 МБ, размер — как в снимке. Файла нет в снимке — `409 file_not_in_document`. |

`Share = {pageId, token, enabled, includeSubpages, digest, publishedAt}`; `digest` — SHA-256 снимка, который сейчас
лежит (или `null`). Ссылка: `<адрес сервера>/s/<token>`, токен — 32 случайных байта в base64url (43 знака).

## Открытые адреса (без входа)

- `GET /s/{token}` — главная страница, `GET /s/{token}/{pageId}` — подстраница из снимка.
- `GET /s/{token}/files/{fileId}` — файл, только если он есть в текущем снимке этой ссылки.
- Ссылка выключена, сменена или не существует — `404` с одинаковой страницей «Ссылка не работает».
- У всех ответов `X-Robots-Tag: noindex, nofollow`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`
  (у файлов — `private, no-cache` и `ETag`), CSP без скриптов. `GET /robots.txt` запрещает всё.

## Снимок (`document`, версия 1)

```ts
{ version: 1, rootPageId, pages: SharedPage[], files: SharedFile[] }

SharedFile = { id, name, mimeType, byteCount }
SharedPage = { id, parentId|null, title, icon|null, cover|null, fullWidth, smallText, blocks: SharedBlock[],
               database?: { columns: string[], rows: { pageId|null, title, icon|null, cells: string[] }[] } }
cover      = { file, offset } | { colors: string[] (#rrggbb), side, offset }
SharedBlock = { id, kind, indent, container|null, text: { string, runs: Run[] }, checked?, collapsed?,
                color?: { text?, background? }, props?: {…}, page?: { id|null, title|null, icon|null } }
Run = { start, length, style } — смещения в UTF-16; style: bold | italic | strikethrough | code | underline |
      link{url} | textColor{color} | backgroundColor{color} | mention{pageId|null, title|null, icon|null} |
      date{text} | equation{latex}
```

`kind` — тип блока приложения (`paragraph`, `heading1`…`heading3`, `bulletItem`, `numberedItem`, `checkbox`,
`pageLink`, `toggle`, `quote`, `callout`, `divider`, `code`, `equation`, `tableOfContents`, `image`, `file`, `video`,
`bookmark`, `table`, `tableRow`, `tableColumn`, `tableCell`, `columnList`, `column`, `database`). `indent` — глубина
при показе (уже урезанная), `container` — колонка, список колонок, таблица или строка таблицы. `props` — только
показ: `icon`, `language`, `width`, `pixelSize`, `url`, `title`, `description`, `hasHeaderRow`, `hasHeaderColumn`,
`columnId`, `widthRatio`, `videoSource`, файлы — id из `files`: `file`, `poster`, `image`, `iconFile`.

## Что видно по ссылке

- Страница и, если включено «Вместе с подстраницами», вся её ветка (подстраницы, строки баз). Корзина не попадает.
- Страница вне опубликованного — в ссылках, упоминаниях и связях — `id: null` без названия: «Нет доступа».
- Встроенная база страницы видна таблицей всегда; строки открываются, только если подстраницы опубликованы.
- Файлы — только те, на которые ссылаются блоки и обложки опубликованных страниц.
