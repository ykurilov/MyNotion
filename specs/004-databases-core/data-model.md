# Data Model: Базы данных — основа

**Date**: 2026-10-21 | **Spec**: [spec.md](spec.md) | **Research**: [research.md](research.md) | **Основа**: [001](../001-core-pages-editor/data-model.md), [002](../002-rich-blocks-text/data-model.md), [003](../003-pages-navigation/data-model.md)

Всё из 001–003 остаётся. Ниже — только новое. Схема базы — версия v9 (восемь новых таблиц, `db_computed` — только на этом Mac).

## Главное: база — это страница (research R1)

- **Полностраничная база** — страница дерева, у которой есть запись `db_database`.
- **Встроенная база** — такая же страница-база, дочерняя к странице-хозяину, с `isInline = да`; в потоке хозяина её показывает блок `database` (как `pageLink` показывает подстраницу).
- **Строка** — страница, родитель которой — страница-база, и `isTemplate = нет`. **Шаблон строки** — то же с `isTemplate = да`.
- Дерево панели не показывает детей страницы-базы и встроенные базы. Корзина, копия ветки, перенос, избранное, вкладки, история версий и обратные ссылки 003 работают с базами и строками как со страницами.

## Page и Block (изменения)

- `Page` новых полей не получает. `updatedAt` строки меняет и правка её ячеек (как правка блока).
- `BlockKind.database` — **новое**: блок встроенной базы; `linkedPageId` — страница-база. Удаление блока уносит базу в корзину вместе с ним; возврат — обратно (как `pageLink` 001).

## db_database — база

| Поле | Тип | Правила |
|------|-----|---------|
| pageId | UUID | первичный ключ, страница-база |
| isInline | да/нет | встроенная |
| defaultTemplateId | UUID? | шаблон по умолчанию; пусто — пустая строка |
| erased | — | стирается вместе со страницей |
| fieldClocks | HLC по полям | `isInline`, `defaultTemplateId` |

Одна база — одна страница. Страница-база без записи (запись ещё не пришла с другого Mac) показывается заглушкой «База загружается».

## db_property — свойство

| Поле | Тип | Правила |
|------|-----|---------|
| id | UUID (по времени) | |
| databaseId | UUID | |
| name | текст | не пустое; одинаковые имена в базе допускаются, редактор формул различает их по id |
| type | текст | `title`, `text`, `number`, `select`, `multiSelect`, `status`, `date`, `checkbox`, `url`, `email`, `phone`, `files`, `createdTime`, `lastEditedTime`, `relation`, `rollup`, `formula`, `uniqueId` |
| config | JSON | настройки типа (ниже); неизвестные ключи сохраняются |
| sortKey | ключ порядка | порядок свойств на странице строки и у новых видов |
| deletedAt | дата? | не пусто — в «Удалённых свойствах»; значения хранятся |
| fieldClocks | HLC | `name`, `typeAndConfig` (одно поле), `sortKey`, `deletedAt` |

У базы ровно одно свойство `title`; его значение — `Page.title` строки (ячейки нет). Тип `title` не меняется и не удаляется.

**config по типам**

| Тип | config |
|-----|--------|
| number | `format` (contracts/property-types.md), `decimals` (`auto` или 0…8), `showAs`: `number` \| `{bar\|ring, color, divideBy, showNumber}` |
| select, multiSelect | `optionSort`: `manual` \| `alphabetical` \| `reverseAlphabetical` |
| status | `groups`: три группы `todo`, `inProgress`, `complete` — `{id, name, color}` (порядок постоянный) |
| date | `dateFormat`: `full` \| `short` \| `mdy` \| `dmy` \| `ymd` \| `relative`; `timeFormat`: `h12` \| `h24` \| `hidden` |
| relation | `targetDatabaseId`, `limit`: `one` \| `none`, `pairedPropertyId?` (ответное свойство в той базе) |
| rollup | `relationPropertyId`, `targetPropertyId`, `calculation` (contracts/property-types.md) , `numberFormat?`, `dateFormat?` |
| formula | `expression` (текст формулы с `prop("…")` по id внутри, показ — по именам), `numberFormat?`, `dateFormat?` |
| uniqueId | `prefix?` (только если Notion 7.39 его даёт — проверяет US1) |
| остальные | `{}` |

## db_select_option — вариант выбора, множественного выбора и статуса

Отдельная запись, чтобы варианты, созданные на двух Mac одновременно, не терялись.

| Поле | Тип | Правила |
|------|-----|---------|
| id | UUID | |
| propertyId | UUID | |
| name | текст | |
| color | текст | 10 цветов Notion: `default`, `gray`, `brown`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `red` |
| sortKey | ключ порядка | порядок в списке (и внутри группы статуса) |
| statusGroup | `todo` \| `inProgress` \| `complete`? | только у статуса |
| deletedAt | дата? | удалённый вариант не показывается; ⌘Z и пришедшая правка его возвращают |
| fieldClocks | HLC | `name`, `color`, `placement` (sortKey + statusGroup), `deletedAt` |

Два варианта с одним именем, созданные на двух Mac, остаются двумя; первый по `id` показывается, второй сливается с ним при следующей правке ячейки (значение переводится на первый).

## db_cell — значение ячейки

| Поле | Тип | Правила |
|------|-----|---------|
| rowId | UUID | строка (страница) |
| propertyId | UUID | |
| value | JSON | по типу (ниже); `null` — пусто, строка ячейки удаляется |
| hlc | HLC | одно поле синхронизации на ячейку |
| sortText | текст? | **только на этом Mac**: сравнимое значение для сортировки и фильтра (нижний регистр, без диакритики) |
| sortNumber | число? | **только на этом Mac**: число, дата (секунды), флажок (0/1), порядок варианта |
| searchText | текст? | **только на этом Mac**: текст для поиска в базе |

Первичный ключ `(rowId, propertyId)`; индексы `db_cell_by_property_number(propertyId, sortNumber)`, `db_cell_by_property_text(propertyId, sortText)`.

**value по типам**

| Тип | value |
|-----|-------|
| text | `InlineText` 002 (оформление, ссылки, упоминания) |
| number | число |
| select, status | id варианта |
| multiSelect | список id вариантов |
| date | `{start, end?, hasTime, timeZone?, reminder?, relative?}`; `reminder` — `atTime` \| `minutes5` … \| `day0At9` \| `day1` \| `day2` \| `week1` (contracts/property-types.md); `relative` (`today` \| `now`) — только у шаблона |
| checkbox | да/нет |
| url, email, phone | текст |
| files | список `{attachment: AttachmentRef}` \| `{url, name}` |
| uniqueId | целое |

`createdTime`, `lastEditedTime` берутся из `Page.createdAt` / `updatedAt`; `relation` — из `db_relation_link`; `rollup`, `formula` — из `db_computed`. Ячеек этих типов нет.

## db_relation_link — связь двух строк

Каждая связь — своя запись: добавления с двух Mac не затирают друг друга (research R7).

| Поле | Тип | Правила |
|------|-----|---------|
| id | UUID | выводится из `(propertyId, rowId, targetRowId)` (UUID v5): одна и та же связь на двух Mac — одна запись |
| propertyId | UUID | свойство-связь стороны, где связь создана как «прямая» (у пары — у свойства с меньшим id) |
| rowId | UUID | |
| targetRowId | UUID | |
| sortKey | ключ порядка | порядок в ячейке |
| isPresent | да/нет | `нет` — связь снята (запись остаётся до чистки следов 001) |
| fieldClocks | HLC | `isPresent`, `sortKey` |

Индексы `(propertyId, rowId)` и `(propertyId, targetRowId)` — ответное свойство читает по второму.
Лимит «1 страница»: при второй связи старая снимается той же правкой.

## db_view — вид

| Поле | Тип | Правила |
|------|-----|---------|
| id | UUID | |
| databaseId | UUID | |
| name | текст | |
| type | текст | `table`; 005 добавит `board`, `calendar`, `gallery`, `list`, `timeline` — неизвестный тип старый Mac показывает таблицей |
| sortKey | ключ порядка | порядок вкладок видов |
| filter | JSON? | дерево `{and\|or: [условие \| группа]}` или одно условие; условие — `{propertyId, operator, value}` (contracts/property-types.md) |
| sorts | JSON | `[{propertyId, direction}]` |
| columns | JSON | `[{propertyId, isVisible, width, wrap, calculation?}]` в порядке колонок; свойства не из списка — видимые, в конце, ширина по умолчанию |
| group | JSON? | `{propertyId, bucket? (дата: day\|week\|month\|year\|relative; число: {from, to, step}), groupSort (`manual` \| `alphabetical` \| `reverseAlphabetical`), groups: [{key, isHidden, isCollapsed}] (ручной порядок), hideEmpty (по умолчанию да)}` |
| layoutOptions | JSON | `openRowsIn` (`sidePeek` — по умолчанию \| `centerPeek` \| `fullPage`), `loadLimit` (10, 25, 50 — по умолчанию, 100), `wrapAllContent` (нет); ключи 005 добавляются сюда, неизвестные сохраняются |
| fieldClocks | HLC | `name`, `type`, `sortKey`, `filter`, `sorts`, `columns`, `group`, `layoutOptions` |

У новой базы — один вид «Таблица». Удалить последний вид нельзя.

## db_row_order — ручной порядок строк вида

В Notion 7.39 ручной порядок свой у каждого вида (сверка, раздел «Главное», п. 1).

| Поле | Тип | Правила |
|------|-----|---------|
| id | UUID | выводится из `(viewId, rowId)` (UUID v5) |
| viewId, rowId | UUID | |
| sortKey | ключ порядка | в том же пространстве ключей, что `Page.sortKey` строк |
| hlc | HLC | одно поле синхронизации |

Место строки в виде без сортировки — `sortKey` этой таблицы, если строку в этом виде двигали, иначе `Page.sortKey` (порядок создания). Перетаскивание ставит ключ между соседями по этому месту. «+ Новая строка» — новый `Page.sortKey` в конце; «Создать» — запись этой таблицы перед первой строкой вида (вверх, как в Notion). Индекс `(viewId, sortKey)`.

## db_computed — вычисленные значения (только на этом Mac)

| Поле | Тип | Правила |
|------|-----|---------|
| rowId, propertyId | UUID | первичный ключ |
| value | JSON | итог формулы или сводки (тип — по формуле) |
| sortText, sortNumber, searchText | | как у `db_cell` |
| isLive | да/нет | формула с `now()` / `today()` |

Пишется подписчиком записи в той же транзакции, что и правка, от которой зависит (research R6); полный пересчёт — на очереди записи. Пустая таблица после миграции заполняется один раз в фоне (как `page_link` 003).

## Индексы поиска и напоминаний

- `search_index` 001: строка на каждое текстовое значение ячейки (`text`, `url`, `email`, `phone`, названия вариантов); путь выдачи — «база › строка».
- Индекс напоминаний 002: ячейки `date` с `reminder` — второй источник напоминаний (research R16).

## Снимок версии (003, `snapshotVersion` 2)

`PageSnapshot` строки дополняется ячейками (`db_cell` строки) и её связями (`db_relation_link`, где она `rowId`). Снимки версии 1 читаются (ячеек нет — восстановление их не трогает).

## Миграция v9

1. Копия базы `MyNotion.backup-v8.sqlite`, тест восстановления из неё.
2. Таблицы `db_database`, `db_property`, `db_select_option`, `db_cell`, `db_relation_link`, `db_view`, `db_row_order`, `db_computed` с индексами.
3. Повтор миграции ничего не меняет; база новее приложения — запись не идёт (как в 002).

## Синхронизация (формат v4)

Новые сущности и поля — contracts/sync-v4-and-export.md. `sortText`, `sortNumber`, `searchText`, `db_computed`, индексы поиска и напоминаний не передаются — каждый Mac считает их сам.
