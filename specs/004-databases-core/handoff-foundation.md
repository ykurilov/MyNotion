# Передача: фундамент 004 (волна A, T001–T030)

Ветка `004-wave-a-foundation`, папка `/Volumes/YurySSD/Мои приложения/MyNotion-004-foundation` (git worktree от `004-databases-core`).
Сравнение замеров — копия базовой ветки `/Volumes/YurySSD/Мои приложения/MyNotion-004-base-measure` (detached, удалить `git worktree remove` после замеров).

## Сделано (отмечено [x] в tasks.md)

T001–T007, T010–T029. Пробы и итоги — research.md R21 (решение по формулам принято), quickstart.md «Этап 0», снимки — `visual-reference/probes/`.
- Ядро: `NotesCore/Database/*` (записи, `RecordClocks`, `FastJSON`, `SortableText`, `NotesTransaction+Database`), миграция v9 (+ локальная `db_cell_search`), `DatabaseSampleGenerator` и `--generate-004-sample`.
- Синхронизация v4: `Sync/DatabaseChangeEncoding.swift`, `DatabaseRecordMerger.swift`; файлы ячеек — в `AttachmentReferenceCounter`.
- `Databases`: модели 18 типов (`PropertyTypes/`), итоги, смена типа, запрос вида (`ViewQuery/`, `LatestViewQuery`), `CellIndexer`, `DatabaseOperations` (основа), фоновый пересчёт формул (`Computation/FormulaRecompute`, `ComputedWriter`, `AppDatabase.withoutAutoCheckpoint`).
- Напоминания дат — `Reminders/CellReminder.swift` и `ReminderIndexer`.
- Дерево: `NotesStore.treeOutline()` (строки баз не читаются), `PageTreeSnapshot(allPages:databases:)`, значок `DatabaseGlyph`.
- Редактор: `BlockKinds/Database.swift`, «/» → `SubpageRequest.createDatabase`, окно создаёт базу (`MainWindowModel`).
- Реестры (T027), `OptionChip`, цвета вариантов (тёмные — со снимка), галерея «Базы» (2 состояния).

## Итог замеров (3 круга) — quickstart.md «Этап 0». T008, T009 отмечены.

## В работе

T008 (переход и вкладки на эталоне с базами) и T030 (замеры): эталон замеров — `ReferenceLibrary` v5 (эталон 003 + базы 004).
Идёт `/tmp/db004-measure.sh`: 3 круга «моя ветка → базовая» (`/tmp/db004-measure-{mine,base}-{1,2,3}.log`, готово — `/tmp/db004-measure.done`).
Круг 1: моя — запуск 0,37–0,91 с, память 52 МБ, вкладки p95 49,2 мс, переход p95 32,4 мс; миграция эталона 1,91 с; базовая — запуск 0,34–0,41 с, память 49,7 МБ, вкладки p95 47,0 мс, переход p95 53,9 мс (выброс VM).
`ReferenceMigrationTests` поправлен: копия ищется по любой версии (эталон 003 в VM мог быть v7) — перепроверить в круге 2–3.

## Осталось

- **T030, холодный запуск** — сделано (ветка `004-coldstart`): причина и цифры — quickstart.md «Этап 0», «Холодный запуск». Первый запуск на холодном эталоне 0,56–0,58 с (база 1,96–1,98).

- Дождаться кругов 2–3, записать в quickstart.md «Этап 0» (переход, вкладки, запуск, память по кругам; миграция ≤ 2 с) и в research.md R21 строку 6; отметить T008, T009, T030.
- Полный прогон затронутых `swift test` (после замеров, чтобы не грузить Mac): NotesCore, Sync, Attachments, Reminders, Databases, DatabaseGrid, PageTree, PageEditor, PageSearch, UIGallery, MarkdownExport, NotionImport, PagePicker.
- Коммит, `git worktree remove ../MyNotion-004-base-measure`.

## Ловушки

- `swift test` в Swift Testing: в замыканиях `store.write { tx in #expect(try …) }` пишите `{ tx throws in … }`, иначе «errors thrown from here are not handled».
- Отмена в тестах с `groupsByEvent = false` — каждое действие в своей группе, иначе падение `registerUndo`.
- `JSONValue` — тип 002 (`BlockProps.swift`); литерала `nil` нет — пишите `.null`.
- Многооператорный SQL с параметрами GRDB не передаёт во второй оператор — по оператору на вызов.
- Код в `PerformanceTests` не видит `package`-API — нужны публичные входы (`ViewQuery.open`, `executeCached`…).
- Замеры в VM: на время своих прогонов не грузить основной Mac; эталон v5 создаётся в VM один раз (долго).
- Пробы: `scripts/vm/run-in-vm.sh uitest --release -only-testing:PerformanceTests/<Класс>` с `MYNOTION_VM_DD=/tmp/mynotion-004a-vm-dd MYNOTION_UITEST_DD=/tmp/mynotion-004a-uitest-dd`.
