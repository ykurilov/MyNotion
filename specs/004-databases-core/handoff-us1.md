# Передача: US1 «Таблица» (T031–T045)

Ветка `004-us1`, папка `/Volumes/YurySSD/Мои приложения/MyNotion-004-us1` (git worktree от `004-databases-core`).
Папки сборки VM: `MYNOTION_VM_DD=/tmp/mynotion-004us1-vm-dd MYNOTION_UITEST_DD=/tmp/mynotion-004us1-uitest-dd`.

## Сделано

- Операции (T035): `Databases/Operations/DatabaseOperations+{Schema,Rows,Cells}.swift`, `UniqueIds.swift`, `DatabaseColumns.swift`.
  Удалить навсегда — свойство остаётся следом с `config.erased = true` (синхронизация без новых записей). Смена типа и
  удаление навсегда отменяются снимком `PropertyState`. Шаг без изменений не ставится (`performChange`).
- `DatabaseOperations.onChange` — только записи страниц и блоков (дерево, открытые страницы); ячейки, свойства, виды —
  уведомление `DatabaseOperations.didChange` (таблицы, страницы строк). Правки с другого Mac — `announce(nil)` в `PagesLibrary`.
- Сетка (T036–T038, T040): `DatabaseGrid/{DatabaseGridView,GridDocumentView,GridHeaderView,RowHoverControls,CellEditorOverlay,
  CellSelection,CellKeyboard,CellClipboard,DatabaseTableController}.swift`, `Cells/*Cell.swift`, `RowMenu/RowMenuPresenter.swift`.
  Ручки строки слева ставятся в документ прокрутки страницы (иначе их не видно и не щёлкнуть).
- Собранный вид базы: `DatabaseViewBar/{DatabaseTableView,ViewBarView}.swift`.
- Страница-база (T041): `NotesCore/Database/DatabasePageContent.swift` — открытый документ страницы-базы показывает один
  блок `database`, ссылающийся на саму базу (не записывается); `App/MainWindow/DatabasePageHost.swift` — фабрика блока
  (встроенная и на всю страницу) и шапка страницы-базы (тело только для чтения). Страница-база создаётся во всю ширину.
- Встроенная (T042): та же фабрика; высота блока — `PageTextView.relayoutDatabaseBlock` (без пересоздания вида).
- Меню колонки, список типов, панель «Изменить свойство», окно «Свойства» (T039) — помощник, ветка влита.
- Страница строки и просмотр сбоку / по центру (T043) — помощник, ветка влита (`RowPeekHost.swift`, `DatabaseRowPage/`).
- Тесты: `DatabasesTests/{DatabaseOperationsTests,UniqueIdNumberingTests}`, `DatabaseGridTests/{CellSelection,CellClipboard,
  PropertyMenu*}Tests`, `DatabaseRowPageTests/`; сценарий `UITests/DatabaseTableTests.swift`; замер
  `PerformanceTests/DatabaseTablePerformanceTests.swift`; галерея — 16 состояний «Базы» (`GalleryDatabasesScene`).

## Осталось

- Галерея в VM, снимки, сверка с Notion (окно ID — префикс), поправки вида.
- Прогон `UITests/DatabaseTableTests` и замера в VM; запись в quickstart.md; отметки T034, T036–T045.

## Ловушки

- Тест с `UndoManager.groupsByEvent = false`: подготовка — операциями без `undoManager`, иначе `registerUndo` падает.
- Пустая группа отмены в тесте становится шагом — шаг без изменений вне `step {}`.
- Хук `block-no-verify` срабатывает на `-n` в одной команде с `git commit` — коммит отдельной командой.
