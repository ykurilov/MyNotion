# Data Model: Страницы и навигация

**Date**: 2026-10-20 | **Spec**: [spec.md](spec.md) | **Research**: [research.md](research.md) | **Основа**: [001](../001-core-pages-editor/data-model.md), [002](../002-rich-blocks-text/data-model.md)

Всё из 001–002 остаётся. Ниже — только изменения. Схема базы — версия v7.

## Page — страница (изменения)

| Поле | Тип | Правила |
|------|-----|---------|
| cover | PageCover? | **новое**. Пусто — обложки нет |
| isFullWidth | да/нет | **новое**, по умолчанию нет |
| isSmallText | да/нет | **новое**, по умолчанию нет |
| favorite | ключ порядка? | **новое**. Пусто — не в избранном; иначе место в разделе «Избранное» (дробный ключ 001) |
| visitedAt | дата? | **новое**. Последнее открытие на любом Mac (research R4: ≥ 2 с или правка) |
| isTemplate | да/нет | **новое**. Шаблон живёт в корне (`parentId` пуст) |
| fieldClocks | HLC по полям | + `cover`, `isFullWidth`, `isSmallText`, `favorite`, `visitedAt`, `isTemplate` |

- `updatedAt` («изменено») меняют только `title`, `icon`, `cover`, `isFullWidth`, `isSmallText`, `isTemplate`, `placement` и блоки; `favorite` и `visitedAt` — нет.
- Страница в корзине сохраняет `favorite`; в разделе «Избранное» не показывается; после возврата — снова там.
- Шаблон с непустым `parentId` (после слияния правок двух Mac) показывается в «Шаблонах», запись не меняется.

**PageCover**: `source` — `gallery(id)` или `file(AttachmentRef)`; `offset` 0…1 (по умолчанию 0,5).
id галереи — из contracts/pages-ui.md, «Галерея»; неизвестный id (от более новой версии) рисуется серой заливкой.
`AttachmentRef` — как в 002; обложка считается ссылкой на файл для счётчика ссылок 002 (файл не стирается, пока он — чья-то обложка).

## DateMention — дата в строке (изменение)

| Поле | Тип | Правила |
|------|-----|---------|
| templateRelative | `today` \| `now`? | **новое**. Ставится, когда «@сегодня» или «@сейчас» вставлены в странице-шаблоне. В копии шаблона дата заменяется датой (и временем для `now`) создания, поле очищается |

Неизвестные ключи даты сохраняются при записи (как `props` в 002).

## Block — блок (изменение)

`props.movedFrom`: UUID? — у копии, созданной «Переместить в» (research R8). Нужен восстановлению версии; в остальном не используется.

## Таблицы базы (новые, только на этом Mac)

### page_link — обратные ссылки (выводится из блоков)

| Колонка | Тип | Правила |
|---------|-----|---------|
| sourceBlockId | UUID | блок со ссылкой |
| sourcePageId | UUID | его страница |
| targetPageId | UUID | на кого ссылается |

Первичный ключ `(sourceBlockId, targetPageId)`; индекс `page_link_by_target(targetPageId)`.
Пишется подписчиком записи в той же транзакции, что и блок. Ссылка-подстраница на своего ребёнка не пишется (research R10).
Миграция v7 создаёт таблицу пустой. Заполняется один раз по всем блокам после первого запуска v7 — в фоне, после готовности редактора (отметка «индекс построен» в таблице `app_meta`); пока не построен, строки обратных ссылок нет.

### page_version — версии страниц

| Колонка | Тип | Правила |
|---------|-----|---------|
| id | UUID (по времени) | |
| pageId | UUID | |
| createdAt | дата | момент снимка |
| deviceName | текст | Mac-автор последней правки, вошедшей в снимок |
| snapshot | BLOB | JSON `PageSnapshot`, сжатый LZFSE |
| summary | JSON | что менялось относительно прошлой версии: `titleChanged`, `iconChanged`, `coverChanged`, `layoutChanged`, `blocksAdded`, `blocksRemoved`, `blocksChanged` |
| byteCount | целое | размер `snapshot` |

Индекс `page_version_by_page(pageId, createdAt)`.
**PageSnapshot**: поля страницы (`title`, `icon`, `cover`, `isFullWidth`, `isSmallText`) и все её блоки всех потоков в формате записи 002 (с `id`, `containerId`, `sortKey`, `color`, `props`). Версия формата снимка — поле `snapshotVersion` (1).

### page_version_due — страницы, ждущие снимка

| Колонка | Тип | Правила |
|---------|-----|---------|
| pageId | UUID | первичный ключ |
| lastChangeAt | дата | последняя правка (своя или пришедшая) |
| deviceName | текст | откуда последняя правка |

Строка пишется подписчиком записи; удаляется, когда снимок записан.

## window_state — вид окна (изменение, только на этом Mac)

| Колонка | Тип | Правила |
|---------|-----|---------|
| tabs | JSON | **новое**: `{active: индекс, items: [Tab]}`; пусто — одна вкладка с `openPageId` (как в 002) |
| collapsedSidebarSections | JSON | **новое**: свёрнутые разделы панели (`recent`, `favorites`, `templates`) |

**Tab**: `id`; `pageId?` (пусто — «Новая вкладка»); `scroll: {blockId, offset}?`; `back: [Entry]`, `forward: [Entry]` до 50; **Entry** — `pageId` и `scroll`.
Закрытые вкладки для ⇧⌘T не хранятся на диске.

## Миграция v7

1. Копия базы `MyNotion.backup-v6.sqlite` (как v6 в 002), тест восстановления из неё.
2. `page`: колонки `cover` (JSON, пусто), `isFullWidth`, `isSmallText`, `isTemplate` (`NOT NULL DEFAULT 0`), `favorite` (TEXT), `visitedAt` (дата); индексы `page_by_favorite(favorite) WHERE favorite IS NOT NULL`, `page_by_visit(visitedAt) WHERE visitedAt IS NOT NULL`; в `fieldClocks` — новые ключи пустыми.
3. Таблицы `page_link` (пустая), `page_version`, `page_version_due`, `app_meta` (ключ — значение, локальные отметки).
4. `window_state`: колонки `tabs`, `collapsedSidebarSections`.
5. Повтор миграции ничего не меняет; база новее приложения — запись не идёт (как в 002).

## Синхронизация (формат v3)

Новые значения изменения страницы — contracts/sync-v3.md. Версии, вкладки, обратные ссылки, свёрнутость разделов не передаются.
