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

## Доделано 21.10.2026 (вторая волна)

- Префикс ID (T039): поле «Префикс» в «Изменить свойство» (`PropertySettings/UniqueIdSettings.swift`), операция
  `setPropertyConfig`; по справке Notion (notion.com/help/unique-id).
- «Вставить слева / справа» открывает под новой колонкой окно имени и типа; вопрос удаления — с затемнением окна.
- Смена типа от 1 000 строк — в фоне (`DatabaseOperations+Background.swift`, образец R21): план на чтении, первая
  запись — тип и варианты, значения пачками по 200 со сверкой (поправленную ячейку не затирает); ⌘Z/⇧⌘Z — по шагу,
  тоже в фоне (`registerRewriteUndo` ставит шаг повтора в самой отмене). Тест: запуск и правки во время перевода ≤ 100 мс.
- Страница-база листается целиком: название уезжает, шапка колонок липнет (`DatabaseGridView.updateStickyHeader`).

## Осталось — на итоговой проверке в VM

- Живьём не видены: липкая шапка, окно новой колонки, затемнение, фоновая смена типа в окне, обрезка шапки, «⠿».
- T044: сверка с живым Notion, размеры меню и окон.
- T045: замеры открытия (p95 и выброс ≈ 480 мс в `CATransaction.flush`), перехода на «Обзор» и вкладок; страница-база
  теперь — вложение во всю высоту строк в тексте страницы, это надо перемерить.
- Новые варианты при вставке выбора из буфера — US2.

## Ловушки

- Тест с `UndoManager.groupsByEvent = false`: подготовка — операциями без `undoManager`, иначе `registerUndo` падает.
- Пустая группа отмены в тесте становится шагом — шаг без изменений вне `step {}`.
- Хук `block-no-verify` срабатывает на `-n` в одной команде с `git commit` — коммит отдельной командой.
