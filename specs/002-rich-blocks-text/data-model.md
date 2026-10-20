# Data Model: Новые блоки и оформление текста

**Date**: 2026-10-19 | **Spec**: [spec.md](spec.md) | **Research**: [research.md](research.md) | **Основа**: [001 data-model](../001-core-pages-editor/data-model.md)

Всё из 001 остаётся. Ниже — только изменения. Схема базы — версия v6.

## Block — блок (изменения)

| Поле | Тип | Правила |
|------|-----|---------|
| kind | перечисление | + `toggle`, `quote`, `callout`, `divider`, `code`, `equation`, `tableOfContents`, `image`, `file`, `video`, `bookmark`, `table`, `tableRow`, `tableColumn`, `tableCell`, `columnList`, `column` |
| indent | целое 0…8 | вложенность внутри потока (R1). Глубина ≤ глубина соседа сверху + 1, если сосед — пункт, чекбокс, переключатель, выноска или цитата; иначе 0. Заголовок глубже 0 — только внутри переключателя, выноски или цитаты. Больше допустимого (после слияния) при показе урезается |
| containerId | UUID? | **новое**. Пусто — блок в потоке страницы. Иначе — контейнер вне текста страницы: колонка (`column`) для её блоков, `columnList` для колонок, `table` для строк и столбцов, `tableRow` для ячеек |
| text | текст с оформлением | как в 001; у блоков без текста хранит: подпись (`image`, `video`), запись LaTeX (`equation`), код (`code`), текст ячейки (`tableCell`); у `divider`, `file`, `bookmark`, `tableOfContents`, `table`, `tableRow`, `tableColumn`, `columnList`, `column` — пусто |
| color | {text: NotionColor?, background: NotionColor?} | **новое**. Цвет всего блока (FR-112); у выноски по умолчанию фон `gray` |
| props | объект по типу блока | **новое**, см. ниже |
| fieldClocks | HLC по полям | `kindAndIndent`, `text`, `isChecked`, `placement` (вместо `sortKey`: контейнер + порядок одной меткой), `color`, `props`, `deleted` |

### Потоки

Поток — блоки одного контейнера по `sortKey`: поток страницы (`containerId` пуст), поток колонки, строки и столбцы таблицы, ячейки строки.
`PageDocument` держит все блоки страницы в одном словаре по id и упорядоченные списки id по потокам. `blocks` — по-прежнему поток страницы (код 001 не меняется); `flow(containerId)` — остальные.
Автосохранение, отмена и синхронизация работают с блоками по id и не различают потоки.

**Сироты после слияния**: блок, чей контейнер удалён или ещё не пришёл, показывается в потоке страницы сразу за своим `columnList` или `table`, а без них — в конце страницы. Запись не меняется: пришёл контейнер — блок встаёт на место.
`columnList` с одной колонкой показывается как её блоки во всю ширину; распадается в запись только правкой Юрия (R3).

### props по типам

| kind | props |
|------|-------|
| callout | `icon`: эмодзи (по умолчанию 💡) |
| code | `language`: id языка (`swift`, `python`, … `plain`) |
| image | `attachment`: AttachmentRef; `width`: доля колонки 0,1…1 (по умолчанию 1); `pixelSize`: [ш, в] |
| file | `attachment`: AttachmentRef |
| video | `source`: `file` \| `youtube` \| `vimeo`; `attachment`: AttachmentRef? (файл); `url`: адрес? (YouTube, Vimeo); `poster`: AttachmentRef?; `title`?; `width` |
| bookmark | `url`; `title`?; `description`?; `image`: AttachmentRef?; `icon`: AttachmentRef?; `fetchedAt`? |
| table | `hasHeaderRow`, `hasHeaderColumn`: да/нет |
| tableColumn | `width`: точки (по умолчанию 120) |
| tableCell | `columnId`: UUID столбца |
| column | `widthRatio`: доля 0,1…0,9 (по умолчанию поровну) |
| toggle, quote, divider, equation, tableOfContents, tableRow, columnList | `{}` |

Неизвестные ключи `props` сохраняются при записи — более новая версия может добавить своё.

**AttachmentRef** — описание файла, уходит на другие Mac: `id` (UUID), `name`, `byteCount` (≤ 104 857 600), `contentType` (UTType), `sha256`, `partCount`.

### Правила

- Строка таблицы: ячейка с `columnId` удалённого столбца не показывается; отсутствующая ячейка — пустая, создаётся при первом вводе.
- У таблицы хотя бы одна строка и один столбец; удаление последнего удаляет таблицу.
- Колонки: 2–5 колонок в `columnList`; доли ширины нормируются к сумме 1 при показе.
- Удаление блока — пометка `deleted` (001); у контейнера помечаются и все блоки внутри одной правкой.
- Удаление строки или столбца, не видевшее правку ячейки, отменяется слиянием — строка или столбец возвращаются (research R3).
- `pageLink` — без изменений.

## Оформление в строке (изменения)

`InlineStyle` получает:

| style | значение | правила |
|-------|----------|---------|
| textColor | NotionColor | один на символ (как `link`) |
| backgroundColor | NotionColor | один на символ |
| mention | pageId | ровно на одном знаке U+FFFC |
| date | DateMention | ровно на одном знаке U+FFFC |
| equation | запись LaTeX | ровно на одном знаке U+FFFC |

**NotionColor**: `gray`, `brown`, `orange`, `yellow`, `green`, `blue`, `purple`, `pink`, `red` (по умолчанию — отсутствие цвета).

**DateMention**: `id` (UUID упоминания — он же id напоминания и уведомления), `start` (дата или дата-время ISO 8601), `includesTime`, `timeZone` (IANA), `reminder`: {`fireAt`: момент UTC}? .

- `normalized()` (001) расширяется: цвета сливаются как ссылки; оформления-атомы без своего U+FFFC отбрасываются; U+FFFC без атома — тоже.
- Текст для поиска и простого текста: U+FFFC упоминания заменяется названием страницы, даты — датой, формулы — записью.
- Вставка скопированной даты получает новый `id` (новое напоминание); ⌘Z возвращает прежний.

## Attachment — копия файла на этом Mac (новое, локальное)

| Поле | Тип | Правила |
|------|-----|---------|
| id | UUID | = `AttachmentRef.id` |
| ref | AttachmentRef | описание как в блоке |
| localPath | текст? | путь относительно `Attachments/`; пусто — файла здесь ещё нет |
| state | `local` \| `uploading` \| `uploaded` \| `remote` \| `downloading` \| `failed` | |
| uploadedParts, downloadedParts | набор номеров | для докачки |
| orphanedAt | время? | ни один блок не ссылается; стирание через 30 дней (research R10) |
| lastError | текст? | для надписи на заглушке |

**Переходы**: `local` → `uploading` → `uploaded`; на другом Mac `remote` → `downloading` → `uploaded`. Ссылка из блока пропала → `orphanedAt`; вернулась → `orphanedAt` пусто. Сирота > 30 дней и все устройства знают удаление → стёрт на Mac и `DELETE /files/{id}`.
Ссылки на файлы пересчитываются в той же транзакции, что `props` блока, через хук ядра «внутри транзакции записи» (001).

## Напоминания (новое)

| Сущность | Поля | Синхронизация |
|----------|------|---------------|
| ReminderState | `mentionId`, `doneAt`?, `doneClock` (HLC) | да, сущность `reminder` в пачке |
| ReminderIndex | `mentionId`, `pageId`, `blockId`, `fireAt`, `deliveredAt`? | нет — выводится из текста блоков в той же транзакции; `deliveredAt` — показано на этом Mac |

Напоминание активно: дата с `reminder` есть в тексте живого блока, страница не в корзине, `doneAt` пусто.

## BlockViewState — вид блока на этом Mac (новое, локальное)

| Поле | Тип |
|------|-----|
| blockId | UUID |
| isCollapsed | да/нет — свёрнут ли переключатель (research R1) |

Не синхронизируется и не входит в отмену. Нет строки — развёрнут.

## Поиск

Структура FTS5 та же. Индексируется `text` всех блоков страницы, в том числе ячеек, колонок, кода, формул и подписей.
U+FFFC упоминания пишется в индекс названием страницы на момент записи.

## Схема v6 и миграция

1. Копия базы `MyNotion.backup-v5.sqlite` (001), тест восстановления из неё.
2. Таблица `block` пересоздаётся: в SQLite нельзя поменять ограничение `CHECK` на `kind`. Новая таблица с новым списком типов и колонками `containerId TEXT`, `color TEXT`, `props TEXT NOT NULL DEFAULT '{}'`; строки копируются; в `fieldClocks` ключ `sortKey` переименовывается в `placement`. Индекс `block_by_container(containerId, sortKey) WHERE containerId IS NOT NULL`.
3. Новые таблицы `attachment`, `reminder_state`, `reminder_index`, `block_view_state`.
4. Проверки: «база v5 эталона → v6» — все блоки, тексты, оформление, конфликты и очередь исходящих на месте; восстановление из копии; повторный запуск миграции ничего не меняет.
5. Выпущенную 001 уже не поменять: этап 0 проверяет, что она делает с базой v6 (GRDB не знает миграции v6). Опасно, только если на Mac останется старая сборка — обе сборки на Mac Юрия заменяются новой. С 002 приложение само проверяет `DatabaseMigrator.hasBeenSuperseded`: база новее приложения — окно «База от новой версии MyNotion — обновите приложение», запись в базу не идёт.
