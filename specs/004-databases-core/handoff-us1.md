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

## Итог проверок

- `swift test` (узко): DatabasesTests, DatabaseGridTests, DatabaseRowPageTests, DatabaseViewBarTests, миграция и записи баз,
  дерево баз — 136 тестов зелёные; AutosaveCoordinator — 10 зелёных.
- `UITests/DatabaseTableTests` в VM — зелёный. Галерея «Базы» — 16 состояний × 2 темы (`/tmp/us1-gallery-2`).
- Замеры — quickstart.md, «US1 «Таблица»».

## Осталось (не закрыто)

- T039: окно ID в живом Notion (есть ли префикс) — не проверено, VM выключен по правилу 21.10.2026.
- T044: сверка с живым Notion не делалась (только с `visual-reference/`); последние правки вида (обрезка шапки, ручка
  «⠿» точками, без курсора в теле страницы-базы) вживую не сняты.
- T045: смена типа — одной транзакцией на главном потоке (SC-305 «окно не замирает > 100 мс» не выполнено); разовый
  выброс открытия ≈ 480 мс в `CATransaction.flush`; переход на «Обзор» и вкладки не перемерены.
- Шапка колонок у базы на всю страницу не липнет при прокрутке страницы: сетка листается сама, название остаётся сверху.
- Новые варианты при вставке выбора из буфера не создаются (только существующие) — US2.

## Ловушки

- Тест с `UndoManager.groupsByEvent = false`: подготовка — операциями без `undoManager`, иначе `registerUndo` падает.
- Пустая группа отмены в тесте становится шагом — шаг без изменений вне `step {}`.
- Хук `block-no-verify` срабатывает на `-n` в одной команде с `git commit` — коммит отдельной командой.
