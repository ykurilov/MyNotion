# Контракт: JSON страниц, блоков, ячеек и видов

Формат закрепляется на этапе 1 (кодеки в `ControlCommands/Codecs/`) и общий для всех групп. Id — UUID строчными буквами. Даты — ISO 8601 с поясом.

## Страница

```json
{ "id": "…", "title": "Встреча 24.10", "icon": "🚀", "link": "mynotion://page/…", "kind": "page|database|row",
  "parentId": "…|null", "path": ["Проекты", "Встреча 24.10"], "hasChildren": true,
  "cover": { "gallery": "gradient-3", "offset": 0.5 } | { "attachmentId": "…", "offset": 0.3 } | null,
  "fullWidth": false, "smallText": false, "isFavorite": false, "isTemplate": false, "inTrash": false,
  "createdAt": "…", "updatedAt": "…" }
```

`link` — адрес страницы: щелчок по нему открывает её в приложении. Блок — `mynotion://page/<id>#<id блока>`.

`page tree` — те же объекты без `link`/`cover`/дат, с `children: […]` до `--depth`.

## Блок

```json
{ "id": "…", "kind": "checkbox", "text": "Купить **молоко**", "rich": { "string": "Купить молоко", "runs": [ { "from": 7, "to": 13, "style": "bold" } ] },
  "indent": 0, "checked": false, "color": { "text": "red", "background": null },
  "props": { … }, "children": [ … ], "linkedPageId": null }
```

- `text` — Markdown строки тем же `InlineMarkdown`, что выгрузка. На вход команд принимается `text` (Markdown строки) или `rich` (точная разметка: `bold`, `italic`, `strikethrough`, `code`, `underline`, `link:<url>`, `textColor:<цвет>`, `backgroundColor:<цвет>`, `mention:<id страницы>`, `date:<ISO>`, `equation`).
- `children` — вложенность для контейнеров (колонки, таблица, раскрывающийся список с содержимым, выноска). Список с отступами отдаётся плоско с `indent`, как хранится.
- `color` — 10 цветов Notion: `gray brown orange yellow green blue purple pink red` и `default`.

### Виды (`block kinds`)

| `kind` | Свойства (`props`) | Заметка |
|--------|--------------------|---------|
| `paragraph`, `heading1…3`, `quote`, `bulletItem`, `numberedItem` | — | заголовок может быть раскрывающимся: `props.toggle` |
| `checkbox` | — | `checked` |
| `toggle` | `expanded` | дети — вложенные блоки |
| `callout` | `icon` (эмодзи) | |
| `code` | `language` | текст без оформления |
| `equation` | — | текст — LaTeX |
| `divider`, `tableOfContents` | — | без текста |
| `pageLink` | — | `linkedPageId`; вставка создаёт подстраницу (`--text` — её название) или ссылку на `--props {"pageId":…}` |
| `image`, `file`, `video` | `attachmentId` или `url`, `width`, `title` | вставка файла — `attachment add` |
| `bookmark` | `url`, `title`, `description` | |
| `table` | `hasHeaderRow`, `hasHeaderColumn`; `rows: [["a","b"],…]` на входе | строки и ячейки (`tableRow`, `tableColumn`, `tableCell`) — внутренние, на вход не принимаются |
| `columnList` | `columns: N`; дети — `column` с `widthRatio` | |
| `database` | `databaseId` | создаётся `db create --inline` |

## Ячейки

Значения по имени свойства в `db row add/update --values`, в ответе `db rows` — так же:

| Тип | Значение | Пример |
|-----|----------|--------|
| `title`, `text`, `url`, `email`, `phone` | строка (Markdown строки для `title`/`text`) | `"Отчёт"` |
| `number` | число | `42.5` |
| `select`, `status` | имя варианта или id; нет варианта — создаётся (`warnings: option_created`), для статуса — ошибка | `"Срочно"` |
| `multiSelect` | массив имён | `["A","B"]` |
| `date` | `"2026-10-24"` или `{ "start": "…", "end": "…", "time": true, "remind": "P1D" }` | |
| `checkbox` | `true/false` | |
| `files` | массив id вложений (добавлять файлы — `attachment add`) | |
| `relation` | массив id строк или названий строк связанной базы | |
| `rollup`, `formula`, `createdTime`, `lastEditedTime`, `uniqueId` | только чтение (`read_only_property`) | в ответе — вычисленное значение и `display` |

`null` — очистить ячейку. Неподходящее значение — `invalid_value` с `details: {"property":…, "type":…, "expected":…, "example":…}`.

## Вид: фильтр, сортировка, группировка

Тот же JSON, что хранит 004 (`FilterNode`, `SortSpec`, `GroupSettings`), но свойства можно называть именем:

```json
{ "and": [
    { "property": "Статус", "operator": "isNot", "value": "Готово" },
    { "or": [ { "property": "Срок", "operator": "isRelativeToToday", "value": "thisWeek" },
              { "property": "Теги", "operator": "contains", "value": "Срочно" } ] } ] }
```

- Операторы — `FilterOperator` 004: `is isNot contains doesNotContain startsWith endsWith isEmpty isNotEmpty equals notEquals greaterThan lessThan greaterThanOrEqual lessThanOrEqual isBefore isAfter isOnOrBefore isOnOrAfter isBetween isRelativeToToday isInGroup`. Какие подходят к типу — `specs/004-databases-core/contracts/property-types.md`; неподходящий — `invalid_value` со списком допустимых.
- Сортировка: `[{"property":"Срок","direction":"ascending"}, …]`.
- Группировка: `{"property":"Статус","sort":"manual|alphabetical|reverseAlphabetical","hideEmpty":true}`.
- В ответе `db view list` — то же с `propertyId` и `property` (имя).

## Ответ `db rows`

```json
{ "view": "…", "groups": [ { "key": "В работе", "count": 12, "rows": [ { "id": "…", "title": "…", "values": { "Статус": "В работе", … } } ] } ],
  "nextCursor": null }
```

Без группировки — одна группа с `key: null`. Порядок строк — порядок вида (включая ручной порядок вида).
