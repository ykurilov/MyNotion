---

description: "Задачи: базы данных — основа"
---

# Tasks: Базы данных — основа

**Input**: Design documents from `/specs/004-databases-core/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Обязательны — конституция, принцип VI (TDD): в каждой фазе тесты пишутся первыми и должны упасть по нужной причине, затем код, затем зелёные все затронутые.

**Organization**: Фазы идут волнами A–E из plan.md (не по приоритету историй: US5 и US7 стоят в волне B рядом с US1, потому что не зависят от сетки). Каждая история — законченный срез: модель, операция с отменой, синхронизация, вид, выгрузка где нужно, галерея, замер.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно параллельно внутри фазы (другие файлы, нет зависимости от незавершённых задач)
- **[Story]**: история из spec.md (US1…US7); `[X]` — сквозные задачи этапа 8, `[Q3]` — этап 9

## Path Conventions

- `PK` = `Packages/MyNotionKit`; модули — `PK/Sources/<Модуль>/`, тесты модулей — `PK/Tests/<Модуль>Tests/`
- Сценарии — `UITests/`, замеры и пробы — `PerformanceTests/`, приложение — `App/`
- Всё живое (UI-тесты, замеры, галерея, пробы) — только в виртуальном Mac: `scripts/vm/run-in-vm.sh uitest|gallery|run`. На основном Mac — только сборка и `swift test`. Каждый worktree — со своими `MYNOTION_VM_DD` и `MYNOTION_UITEST_DD`
- Сверка с Notion — только подстраница «MyNotion — блоки 002» или её подстраница «MyNotion — базы 004», один замок `scripts/vm/run-in-vm.sh lock -- …` на сеанс, без ⌘Z в Notion, ничего вне неё не менять (research R20)
- Долгий прогон ждать внутри хода: PID в файл и `kill -0`, или строка итога в логе; не `pgrep -f`. Ход заканчивается только итогом фазы, не «жду прогона»

---

## Phase 1: Setup — волна A, агент «Фундамент»

**Purpose**: новые модули и реестры «файл на пункт», чтобы параллельные этапы добавляли файлы, а не правили общие

- [x] T001 В `PK/Package.swift` добавить цели и тестовые цели: `Databases` (NotesCore, GRDB, Formulas), `Formulas` (без зависимостей), `DatabaseGrid` (NotesCore, Databases, VisualStyle, Attachments), `DatabaseViewBar` (Databases, DatabaseGrid, VisualStyle), `DatabaseRowPage` (Databases, DatabaseGrid, PageEditor), `NotionSchemaFetch` (Formulas); папки `PK/Sources/NotesCore/Database/`, `PK/Sources/Databases/{PropertyTypes,Operations,ViewQuery,Computation,RowTemplates}/`, `PK/Sources/DatabaseGrid/{Cells,PropertySettings,PropertyMenu,Grouping,Calculations}/`, `PK/Sources/MarkdownExport/DatabaseExport/`
- [x] T002 В `project.yml` подключить новые модули к приложению `MyNotion`; проверить `xcodegen generate && xcodebuild build -scheme MyNotion` на основном Mac

---

## Phase 2: Foundational (этап 0) — волна A, агент «Фундамент»

**Purpose**: пробы рисков, модель v9, формат v4, модели значений всех типов, ядро запроса вида, реестры. ⚠️ Ни одна история не начинается до конца фазы.

### Пробы рисков (первыми, research R20; каждая — цифра и снимок отрисовки)

- [x] T003 Генератор эталона баз в `PK/Sources/NotesCore/Fixtures/DatabaseSampleGenerator.swift` (состав — quickstart.md: «Задачи» 10 000 × 30, «Проекты» 500, «Обзор» со встроенной базой, вид «Задачи — работа»; пишет записи напрямую, без операций — для проб), флаг `--generate-004-sample` в `App/MyNotionApp.swift`
- [x] T004 Проба сетки в `PerformanceTests/Probes/DatabaseGridProbeTests.swift` + черновой `PK/Sources/DatabaseGrid/DatabaseGridView.swift` (видимые строки слоями, Core Text, переиспользование): открытие «Задачи» до нарисованного первого экрана ≤ 50 мс; прокрутка до конца и обратно — кадр p95 ≤ 16 мс, худший ≤ 50 мс; 5 снимков во время прокрутки — текст во всех видимых строках (доля закрашенного в рамках ячеек > 0); правка ячейки (буква, флажок) ≤ 50 мс; прогон `scripts/vm/run-in-vm.sh uitest --release -only-testing:PerformanceTests/DatabaseGridProbeTests`
- [x] T005 [P] Проба запроса в `PerformanceTests/Probes/DatabaseQueryProbeTests.swift` + черновой `PK/Sources/Databases/ViewQuery/ViewQuerySQL.swift`: фильтр «работа» (3 условия, И/ИЛИ) + две сортировки (одна по `db_computed`) ≤ 30 мс; смена фильтра до экрана ≤ 100 мс; поиск ≤ 50 мс на символ; `EXPLAIN QUERY PLAN` — индексы, без полного прохода `db_cell`
- [x] T006 [P] Проба формул в `PerformanceTests/Probes/FormulaProbeTests.swift` + черновой разбор и вычисление в `PK/Sources/Formulas/` (только нужное пробе: `prop`, арифметика, `if`, `dateBetween`, `now`, `map`, `current`) и фоновый пересчёт по R21 (`PK/Sources/Databases/Computation/FormulaRecompute.swift`, `ComputedWriter.swift`): 3 формулы × 10 000 строк — в фоне, вне транзакции записи, короткими пачками, итог сходится с подсчётом «в лоб»; правка ячейки во время пересчёта ждёт ≤ 50 мс p95; пачка не затирает поправленную строку; одна правка с пересчётом строки ≤ 5 мс; снимок сетки с итогами
- [x] T007 [P] Проба связей в `PerformanceTests/Probes/RelationProbeTests.swift`: правка часов задачи пересчитывает сводку проекта в той же транзакции ≤ 10 мс; проект с 1 000 задач в корзину и обратно ≤ 200 мс; сводки совпадают с подсчётом «в лоб»
- [x] T008 [P] Проба встроенной базы в `PerformanceTests/Probes/InlineDatabaseProbeTests.swift`: «Обзор» — переход ≤ 50 мс, набор p95 ≤ 50 мс, снимок — сетка нарисована, строк — по пределу 50; переход между обычными страницами и вкладки на эталоне с базами — не хуже 003 (27–31 / ≈ 45 мс), три прогона
- [x] T009 Записать итоги T004–T008 в `specs/004-databases-core/research.md` (R21, с датой, цифрами и путями снимков `visual-reference/probes/`) и `quickstart.md`; при провале пункта зафиксировать запасной путь (R20) до начала зависящей истории; коммит «Этап 0: пробы»

### Тесты фундамента (до кода, должны быть красными)

- [x] T010 [P] Тест миграции v9 в `PK/Tests/NotesCoreTests/DatabaseMigrationV9Tests.swift`: эталон v8 → v9 — страницы, блоки, вложения, версии, очередь исходящих на месте; восемь таблиц и индексы по data-model.md; копия `MyNotion.backup-v8.sqlite` и восстановление; повтор ничего не меняет; база новее — запись не идёт
- [x] T011 [P] Тест записей в `PK/Tests/NotesCoreTests/DatabaseRecordsTests.swift`: база, свойство, вариант, вид, ячейка, связь, порядок строки — запись, чтение, `fieldClocks`, неизвестные ключи `config` и `layoutOptions` сохраняются; правка ячейки меняет `updatedAt` строки; `NotesChanges` несёт все новые записи; удаление строки в корзину ячейки не трогает, стирание — стирает ячейки, связи и порядок
- [x] T012 [P] Тест формата v4 в `PK/Tests/SyncTests/SyncPayloadV4Tests.swift`: кодирование и разбор всех сущностей contracts/sync-v4-and-export.md; `formatVersion` 4; пачки v1–v3 читаются; Mac с форматом 3 пачку v4 не применяет и показывает «Обновите MyNotion на этом Mac»
- [x] T013 [P] Тест слияния в `PK/Tests/SyncTests/ChangeMergerV4Tests.swift`: «позднее побеждает» для каждого поля; разные ячейки одной строки с двух клиентов — обе; одновременные варианты и связи — все на месте; связь с id из UUID v5 с двух клиентов — одна запись; ячейка раньше свойства хранится и показывается после; снимок для нового Mac переносит всё
- [x] T014 [P] Тесты моделей значений в `PK/Tests/DatabasesTests/PropertyTypes/<Тип>Tests.swift` — по файлу на тип, строго по contracts/property-types.md: JSON значения, сравнимые колонки (порядок сортировки, пустые в конце), текст показа и CSV (дословно примеры contracts/sync-v4-and-export.md), разбор из CSV, условия фильтра, ключи групп, итоги, смена типа (таблица «Смена типа»)
- [x] T015 [P] Тест запроса в `PK/Tests/DatabasesTests/ViewQueryCoreTests.swift`: дерево фильтра И/ИЛИ с вложенной группой, несколько сортировок, ручной порядок вида (`db_row_order`, иначе `Page.sortKey`), строки вне корзины и не шаблоны, окно видимых строк; итог совпадает с фильтром «в лоб» на 1 000 случайных строк
- [x] T016 [P] Тест индексатора в `PK/Tests/DatabasesTests/CellIndexerTests.swift`: `sortText`, `sortNumber`, `searchText` пишутся в той же транзакции; строки `search_index` для текстовых значений; напоминание даты — в индексе напоминаний 002
- [x] T017 [P] Тест дерева в `PK/Tests/PageTreeTests/DatabaseInTreeTests.swift`: дети страницы-базы и встроенные базы не показываются; полностраничная база — значок таблицы, без стрелки; корзина и возврат базы — со строками
- [x] T018 [P] Тест реестров в `PK/Tests/DatabaseGridTests/RegistriesTests.swift`: типы, меню колонки, список типов (порядок contracts/property-types.md), окна настроек, кнопки строки вида, меню строки, места страницы строки собираются из описателей в порядке contracts/database-ui.md

### Код фундамента

- [x] T019 Модель `PK/Sources/NotesCore/Database/` (`DatabaseSchema`, `DatabaseProperty`, `SelectOption`, `CellRecord`, `RelationLink`, `DatabaseView`, `RowOrder`) и `BlockKind.database` в `PK/Sources/NotesCore/Model/Block.swift` строго по data-model.md (T011)
- [x] T020 Миграция v9 в `PK/Sources/NotesCore/Storage/SchemaMigrations.swift`; чтение и запись в `RowMapping.swift`, `NotesTransaction.swift` (новые записи, `NotesChanges.database`, `updatedAt` строки при правке ячейки), стирание со страницей (T010, T011)
- [x] T021 Синхронизация v4: `PK/Sources/Sync/SyncPayload.swift`, `Outbox.swift`, `ChangeMerger.swift`, `RemoteChangeApplier.swift`, `SyncSnapshot.swift`; файлы ячеек «Файлы и медиа» — в очередь докачки `PK/Sources/Attachments/AttachmentTransfer.swift` и счётчик ссылок 002 (T012, T013)
- [x] T022 Модели значений 18 типов в `PK/Sources/Databases/PropertyTypes/<Тип>.swift` и протокол `PropertyType.swift` (без вида; итоги и смена типа — здесь) (T014)
- [x] T023 Ядро запроса `PK/Sources/Databases/ViewQuery/` (дерево фильтра → SQL, сортировки, ручной порядок вида, группы, окно видимых строк, отмена прежнего запроса) — из черновика T005 (T015)
- [x] T024 `PK/Sources/Databases/CellIndexer.swift` (подписчик записи) и второй источник напоминаний в `PK/Sources/Reminders/ReminderIndexer.swift` (T016)
- [x] T025 Операции-основа `PK/Sources/Databases/Operations/DatabaseOperations.swift`: `perform` и шаг отмены, создать базу (полностраничную и встроенную), добавить свойство, записать ячейку — остальное истории пишут в своих файлах-расширениях `DatabaseOperations+<Тема>.swift`
- [x] T026 Дерево и блок: `PK/Sources/PageTree/PageOutlineDataSource.swift` (скрыть детей базы и встроенные, значок таблицы), скелет `PK/Sources/PageEditor/BlockKinds/Database.swift` (вложение-заглушка встроенной базы, «/База данных — встроенная», «/База данных — на всю страницу») (T017)
- [x] T027 Реестры: типы в `PK/Sources/DatabaseGrid/Cells/CellKind.swift`, меню колонки `PropertyMenu/PropertyMenuItem.swift`, список типов `PropertyMenu/PropertyTypePicker.swift`, окна настроек `PropertySettings/PropertySettingsPanel.swift`, кнопки строки вида `PK/Sources/DatabaseViewBar/ViewBarItem.swift`, меню строки `DatabaseGrid/RowMenuItem.swift`, места страницы строки `PK/Sources/DatabaseRowPage/RowPagePlaces.swift`; пункт «Выгрузить базу» — место в реестре меню «•••» 003 (T018)
- [x] T028 [P] Цвета вариантов (10 цветов Notion в обеих темах, со снимков) и размеры сетки в `PK/Sources/VisualStyle/`; плашка варианта `DatabaseGrid/OptionChip.swift` (её берут US2, US3, US4)
- [x] T029 [P] Состояния галереи «база пустая», «таблица эталона» в `PK/Sources/UIGallery/GalleryCatalog.swift`
- [ ] T030 Затронутые тесты зелёные (`swift test`); замер запуска, памяти, перехода и вкладок в виртуальном Mac не хуже 003; миграция эталона v9 ≤ 2 с; запись в quickstart.md, раздел «Этап 0»; коммит

**Checkpoint**: фундамент готов — волна B стартует.

---

## Phase 3: User Story 1 — База и таблица (Priority: P1) 🎯 MVP — волна B, агент «Таблица»

**Goal**: полностраничная и встроенная база, сетка, колонки, строки, правка и выделение ячеек простых типов, страница строки.

**Independent Test**: spec, US1.

### Tests for User Story 1

- [ ] T031 [P] [US1] `PK/Tests/DatabasesTests/DatabaseOperationsTests.swift`: создать обе базы (пустая, одна колонка «Название»); свойство — добавить, переименовать, переставить, ширина, вставить слева/справа, дублировать со значениями, удалить (в «Удалённые свойства») и вернуть, удалить навсегда; строка — «+ Новая строка» (в конце), «Создать» (вверху вида), дублировать, в корзину, перетащить (только `db_row_order` этого вида); смена типа с переводом значений и ⌘Z целиком; каждая — один шаг отмены
- [ ] T032 [P] [US1] `PK/Tests/DatabaseGridTests/CellSelectionTests.swift` и `CellClipboardTests.swift`: прямоугольник ⇧-стрелками и протяжкой, ⌘A; ⌘C — TSV и HTML-таблица; ⌘V с добавлением строк и обрезкой колонок; ⌫ стирает; вставка одним шагом отмены
- [ ] T033 [P] [US1] `PK/Tests/DatabasesTests/UniqueIdTests.swift`: номера 1, 2, 3 по созданию, одно свойство ID на базу, номер не переиспользуется после корзины
- [ ] T034 [P] [US1] XCUITest `UITests/DatabaseTableTests.swift`: «/База данных — встроенная» и «— на всю страницу»; колонки простых типов; 20 строк; правка, Esc, Enter, Tab; выделение и ⌘C/⌘V; открыть строку «ОТКРЫТЬ» сбоку, по центру, на всю страницу; свойства на странице строки; ⌘Z по шагам; перезапуск — всё на месте

### Implementation for User Story 1

- [ ] T035 [US1] Операции `PK/Sources/Databases/Operations/DatabaseOperations+{Schema,Rows,Cells}.swift` и `PK/Sources/Databases/UniqueIds.swift` (выдача номеров) (T031, T033)
- [ ] T036 [US1] Сетка `PK/Sources/DatabaseGrid/DatabaseGridView.swift` из черновика T004: шапка колонок с иконками, протяжка края, перетаскивание колонок, «+» и «•••» в шапке, «+ Новая строка», наведение строки («+», «⠿», «ОТКРЫТЬ», флажок), полоса «N выбрано»; данные — окно видимых строк из `ViewQuery`
- [ ] T037 [US1] Выделение, клавиши и буфер в `PK/Sources/DatabaseGrid/{CellSelection,CellKeyboard,CellClipboard}.swift`, редактор ячейки `CellEditorOverlay.swift` (T032)
- [ ] T038 [US1] Ячейки простых типов в `PK/Sources/DatabaseGrid/Cells/{Title,Text,Number,Checkbox,URL,Email,Phone,CreatedTime,LastEditedTime,UniqueId}Cell.swift`; ссылка, email, телефон — кнопка при наведении
- [ ] T039 [US1] Меню колонки `PK/Sources/DatabaseGrid/PropertyMenu/` (пункты US1: имя, «Изменить свойство», «Сменить тип», вставить, дублировать, удалить с подтверждением), список типов с поиском в две колонки, панель «Изменить свойство» справа, окно «Свойства» базы с «Удалёнными свойствами»; проверить в Notion окно ID (префикс есть — сделать, нет — убрать из data-model.md и contracts)
- [ ] T040 [US1] Меню строки (правый щелчок) `PK/Sources/DatabaseGrid/RowMenu/` по contracts/database-ui.md; ⌥-щелчок — сбоку, ⇧⌘↩ — новая вкладка
- [ ] T041 [US1] Полностраничная база в `App/MainWindow/DatabasePageHost.swift`: название, иконка, обложка 003, строка видов (только вкладка «Таблица» и кнопки из реестра — их добавят US3, US6), сетка во всё окно
- [ ] T042 [US1] Встроенная база в `PK/Sources/PageEditor/BlockKinds/Database.swift`: сетка во вложении, предел загрузки 50 и «Загрузить ещё», ⤢, ручка и меню блока; переход на страницу читает только первый экран
- [ ] T043 [US1] Страница строки `PK/Sources/DatabaseRowPage/`: свойства под названием (место 003), «+ Добавить свойство», «Пусто»; просмотр сбоку и по центру (`RowPeekHost.swift`, «»» и «⤢», Esc); «Открывать строки» — пока из `layoutOptions` вида (переключатель — US3)
- [ ] T044 [US1] Состояния галереи: пустая встроенная и полностраничная, таблица эталона, наведение строки, выделение ячеек, правка ячейки, меню колонки, список типов, панель «Изменить свойство», подтверждение удаления, меню строки, страница строки, просмотр сбоку и по центру — в обеих темах; сверка с `visual-reference/` и живым Notion (размеры с «≈» — снять и поправить contracts/database-ui.md)
- [ ] T045 [US1] Затронутые тесты зелёные; замеры: открытие «Задачи», прокрутка, правка ячейки, смена типа на 10 000, переход на «Обзор», переход и вкладки — со снимками; запись в quickstart.md; коммит

**Checkpoint**: US1 работает и проверяется сама.

---

## Phase 4: User Story 5 — Формулы (Priority: P5) — волна B, агент «Формулы»

**Goal**: язык формул Notion 2.0 (подмножество contracts/formulas.md), пересчёт, редактор.

**Independent Test**: spec, US5.

### Tests for User Story 5

- [x] T046 [P] [US5] `PK/Tests/FormulasTests/ParserTests.swift`: синтаксис contracts (литералы, старшинство, методы и функции, `let`/`lets`, `current`/`index`, комментарии); ошибки с местом и текстом по-русски — дословно примеры contracts
- [x] T047 [P] [US5] `PK/Tests/FormulasTests/FunctionsTests.swift`: каждая функция contracts — по примеру Notion (итоги примеров — из справки редактора формул Notion, снять в живом Notion одним замком); пустое и деление на ноль — пусто; неподдержанная — ошибка с названием
- [x] T048 [P] [US5] `PK/Tests/FormulasTests/TypeCheckTests.swift`: вывод типа итога, ошибки типов, круг «Итог → Сумма → Итог»
- [x] T049 [P] [US5] `PK/Tests/DatabasesTests/FormulaRecomputeTests.swift`: правка зависимого значения пересчитывает в той же транзакции; переименование свойства переписывает формулы; полный пересчёт — в фоне по R21 (механизм фундамента `FormulaRecompute`): вне транзакции записи, короткими пачками, не затирает поправленную строку, до готовности — прежнее значение; «живые» формулы — раз в минуту только у открытого вида (подменённые часы)
- [x] T050 [P] [US5] XCUITest `UITests/FormulaEditorTests.swift`: формулы из spec, US5; ошибка подсвечена, «Готово» неактивно; итог для первой строки; фильтр и сортировка по формуле (через операции — кнопки вида появятся в US3)

### Implementation for User Story 5

- [x] T051 [US5] Модуль `PK/Sources/Formulas/`: `Lexer`, `Parser`, `FormulaTypes`, `Evaluator`, `Functions/{Logic,Numbers,Text,Dates,Lists,Pages}.swift`, `FunctionCatalog.swift` (описания и примеры для редактора), `FormulaErrors.swift` (T046–T048)
- [x] T052 [US5] Пересчёт `PK/Sources/Databases/Computation/` (`ComputationHook` — подписчик записи, граф зависимостей базы, `db_computed`; полный пересчёт и первое заполнение — на `FormulaRecompute` и `ComputedWriter` фундамента по R21; «живые» формулы) (T049)
- [x] T053 [US5] Ячейка `PK/Sources/DatabaseGrid/Cells/FormulaCell.swift` и формат итога (числа и даты — форматы свойства)
- [x] T054 [US5] Редактор `PK/Sources/DatabaseGrid/PropertySettings/FormulaEditor/` по contracts/formulas.md и `notion-formula-editor*.png`: поле с подсветкой (свойства — плашками), «Предпросмотр с <строка ▾>» и итог, «Тип: …», список свойств и функций по разделам с поиском, описание с примерами, ошибки (T050)
- [x] T055 [US5] Состояния галереи: редактор пустой, с итогом, с ошибкой, с кругом; ячейки формул всех типов итога — в обеих темах; сверка с Notion
- [x] T056 [US5] Затронутые тесты зелёные; замеры (R21): новая формула на 10 000 — в фоне, без блокировки, итог сходится с подсчётом «в лоб», правка во время пересчёта ждёт ≤ 50 мс p95; первое заполнение `db_computed` (≤ 5 с, в фоне); правка с пересчётом; открытие «Задачи» с сортировкой по формуле; запись в quickstart.md; коммит

**Checkpoint**: US5 работает и проверяется сама (вливается после US1).

---

## Phase 5: User Story 7 — Импорт из Notion и выгрузка (Priority: P7) — волна B, агент «Импорт»

**Goal**: выгрузка базы CSV + Markdown + схема, импорт своей выгрузки и выгрузки Notion с типами и связями.

**Independent Test**: spec, US7.

### Tests for User Story 7

- [ ] T057 [P] [US7] Образец выгрузки Notion в `PK/Sources/NotionImport/Fixtures/NotionDatabases/`: две связанные базы со всеми типами, встроенная и полностраничная, тела строк, одинаковые названия — выгрузить из живого Notion (страница «MyNotion — базы 004», одним замком, «Include subpages» вкл)
- [ ] T058 [P] [US7] `PK/Tests/MarkdownExportTests/DatabaseExportTests.swift`: CSV, Markdown строк и схема дословно по contracts/sync-v4-and-export.md; встроенная — в папке хозяина; шаблоны — в `Шаблоны/`
- [ ] T059 [P] [US7] `PK/Tests/NotionImportTests/NotionDatabaseImportTests.swift` на образце T057: место базы, строки ↔ файлы, каждый признак таблицы типов, связи по 32 hex (CSV и `.md`), пара — двусторонняя, «Создано» / «Изменено» в `createdAt` / `updatedAt`, 100 % значений, отчёт дословно; выгрузка без «Include subpages» — строки без тел и строка отчёта
- [ ] T060 [P] [US7] `PK/Tests/NotionImportTests/DatabaseRoundTripTests.swift`: эталон баз → своя выгрузка → импорт — схема, варианты, формулы, связи, виды, шаблоны, значения один в один

### Implementation for User Story 7

- [ ] T061 [US7] Выгрузка `PK/Sources/MarkdownExport/DatabaseExport/` (`DatabaseCSVWriter`, `RowMarkdownWriter`, `DatabaseSchemaFile`) и база в общей выгрузке 001; на очереди чтения (T058)
- [ ] T062 [US7] Импорт `PK/Sources/NotionImport/NotionDatabaseReader.swift` (место, строки, типы, второй проход связей), импорт своей схемы `DatabaseSchemaImport.swift`; запись через `DatabaseOperations` (T059, T060)
- [ ] T063 [US7] Отчёт импорта баз в `App/Settings/NotionImportView.swift`; пункт «Выгрузить базу» в меню «•••» страницы-базы
- [ ] T064 [US7] Затронутые тесты зелёные; замеры: импорт 10 000 строк (≤ 60 с, отзыв правки ≤ 100 мс), выгрузка «Задачи» (≤ 10 с); CSV выгрузки открыт в Numbers в виртуальном Mac (снимок); запись в quickstart.md; коммит

**Checkpoint**: US7 работает и проверяется сама (вливается после US5).

---

## Phase 6: User Story 2 — Выбор, статус, дата и файлы (Priority: P2) — волна C, агент «Типы»

**Goal**: варианты с цветами, статус с группами, дата с диапазоном и напоминанием, файлы, форматы числа.

**Independent Test**: spec, US2.

### Tests for User Story 2

- [ ] T065 [P] [US2] `PK/Tests/DatabasesTests/SelectOptionOperationsTests.swift`: создать из ячейки (случайный цвет не как у предыдущего), переименовать, цвет, удалить из всех строк и ⌘Z, порядок, сортировка вариантов; статус — три группы и варианты по умолчанию; одинаковые имена с двух Mac сливаются при правке ячейки
- [ ] T066 [P] [US2] `PK/Tests/DatabasesTests/DatePropertyTests.swift` и `DatabaseReminderTests.swift` (подменённые часы): диапазон, время, форматы (contracts), напоминания всех вариантов — момент срабатывания; «сделано» синхронизируется как в 002
- [ ] T067 [P] [US2] `PK/Tests/DatabasesTests/FilesPropertyTests.swift`: несколько файлов и ссылок, лимит 100 МБ, счётчик ссылок 002 — файл не стирается, пока он в ячейке или в версии
- [ ] T068 [P] [US2] XCUITest `UITests/SelectStatusDateTests.swift`: сценарии spec, US2; перезапуск

### Implementation for User Story 2

- [ ] T069 [US2] Операции вариантов `PK/Sources/Databases/Operations/DatabaseOperations+Options.swift` (T065)
- [ ] T070 [US2] Ячейки и окна `PK/Sources/DatabaseGrid/Cells/{Select,MultiSelect,Status}Cell.swift` (окно «Найти вариант…», «Выберите вариант или создайте», ручки, «⋯» варианта с цветами) и настройки `PropertySettings/{SelectSettings,StatusSettings}.swift`
- [ ] T071 [US2] Дата `PK/Sources/DatabaseGrid/Cells/DateCell.swift` (календарь с понедельника, «Дата окончания», «Формат даты ›», «Включить время», «Напомнить ›», «Очистить»), напоминания из ячеек в `ReminderNotifications` (T066)
- [ ] T072 [US2] Файлы `PK/Sources/DatabaseGrid/Cells/FilesCell.swift` (окно «Загрузить» / «Ссылка», перетаскивание из Finder, уменьшенные картинки) (T067)
- [ ] T073 [US2] Число: `PropertySettings/NumberSettings.swift` — «Формат числа» с фильтром (снять полный список валют прокруткой в Notion), знаки после запятой, «Показывать как» (полоса, кольцо с цветом, «Разделить на», «Показывать число»)
- [ ] T074 [US2] Состояния галереи: окна выбора, статуса, даты (все переключатели), файлов, настроек числа, плашки 10 цветов, полоса и кольцо — в обеих темах; сверка с `visual-reference/` и живым Notion
- [ ] T075 [US2] Затронутые тесты зелёные; замер правки ячейки выбора и даты; запись в quickstart.md; коммит

**Checkpoint**: US2 работает и проверяется сама.

---

## Phase 7: User Story 3 — Фильтры, сортировка, поиск, скрытие и группировка (Priority: P3) — волна C, агент «Вид»

**Goal**: строка вида и настройки вида, несколько видов, группы, итоги и перенос текста (Q1).

**Independent Test**: spec, US3.

### Tests for User Story 3

- [ ] T076 [P] [US3] `PK/Tests/DatabasesTests/ViewSettingsOperationsTests.swift`: фильтр простой и расширенный (правило, группа, «Превратить в группу», «Удалить фильтр»), сортировки (добавить, переставить, ✕, «Удалить сортировку» — все), видимость, группировка (свойство, шаг, порядок, скрытые и свёрнутые, «Скрывать пустые» по умолчанию), виды (добавить, переименовать, дублировать «Таблица (1)», удалить — не последний), «Открывать строки», «Предел загрузки», перенос, итоги колонок — каждая с ⌘Z
- [ ] T077 [P] [US3] `PK/Tests/DatabasesTests/NewRowDefaultsTests.swift`: значения новой строки по каждому условию contracts и по группе; «Создать» — вверх вида
- [ ] T078 [P] [US3] `PK/Tests/DatabasesTests/ColumnCalculationTests.swift`: каждое вычисление contracts по строкам после фильтра и поиска, у групп — свои
- [ ] T079 [P] [US3] XCUITest `UITests/ViewFilterSortGroupTests.swift`: сценарии spec, US3 на эталоне 10 000; второй вид со своими настройками; перезапуск

### Implementation for User Story 3

- [ ] T080 [US3] Операции вида `PK/Sources/Databases/Operations/DatabaseOperations+Views.swift`, значения новой строки `PK/Sources/Databases/ViewQuery/NewRowDefaults.swift` (T076, T077)
- [ ] T081 [US3] Строка вида `PK/Sources/DatabaseViewBar/`: вкладки видов и меню вкладки, «+» вида, Фильтр, Сортировка, Поиск с подсветкой найденного, «Настройки вида», синие значки активных, полоса чипов
- [ ] T082 [US3] Окна фильтра (простое и расширенное, условия по типам из моделей этапа 0), сортировки, видимости свойств, группировки, раскладки (`DatabaseViewBar/Panels/`); пункты меню колонки «Фильтр», «Сортировка ›», «Группировка», «Посчитать ›», «Скрыть», «Переносить текст»
- [ ] T083 [US3] Группы в сетке `PK/Sources/DatabaseGrid/Grouping/` (заголовки, сворачивание, «+ Новая строка» группы, «+ Новая группа») и раскладка групп в `DatabaseGridView.swift`; итоги `DatabaseGrid/Calculations/` (строка под «+ Новая строка», «Посчитать» при наведении); перенос текста — высота строки по содержимому (T078)
- [ ] T084 [US3] Состояния галереи: строка вида с активными значками и чипами, окна фильтра (простое, расширенное с вложенной группой, условия даты), сортировки с двумя уровнями, видимость, группировка и настройки групп, таблица с группами и итогами, перенос текста, раскладка, меню вкладки, поиск — в обеих темах; сверка с `visual-reference/` и живым Notion
- [ ] T085 [US3] Затронутые тесты зелёные; замеры: смена фильтра, сортировки, группировки, видимости (≤ 100 мс), поиск (≤ 50 мс на символ), прокрутка с группами и переносом, открытие «Задачи — работа»; запись в quickstart.md; коммит

**Checkpoint**: US3 работает и проверяется сама.

---

## Phase 8: User Story 4 — Связи и сводки (Priority: P4) — волна C, агент «Связи»

**Goal**: связь с парой и лимитом, сводки, пересчёт по связям.

**Independent Test**: spec, US4.

### Tests for User Story 4

- [ ] T086 [P] [US4] `PK/Tests/DatabasesTests/RelationOperationsTests.swift`: связь с другой и своей базой, лимит «1 страница» снимает прежнюю, ответное свойство (вкл/выкл позже — связи на месте), удаление свойства-пары, правка с любой стороны; ⌘Z каждого
- [ ] T087 [P] [US4] `PK/Tests/SyncTests/RelationLinkMergeTests.swift`: связи с двух клиентов, снятие и добавление одной связи одновременно — «позднее побеждает»; связь без строки-цели хранится
- [ ] T088 [P] [US4] `PK/Tests/DatabasesTests/RollupTests.swift`: каждое вычисление contracts; пересчёт при правке, корзине, возврате, стирании строки-цели; сводка по формуле
- [ ] T089 [P] [US4] XCUITest `UITests/RelationRollupTests.swift`: сценарии spec, US4; «Найти или создать страницу…» создаёт строку в цели

### Implementation for User Story 4

- [ ] T090 [US4] Операции `PK/Sources/Databases/Operations/DatabaseOperations+Relations.swift` (T086, T087)
- [ ] T091 [US4] Сводки в `PK/Sources/Databases/Computation/Rollups.swift` рядом с формулами US5; обход связей в формулах (`current.prop`) — через тот же индекс (T088)
- [ ] T092 [US4] Ячейки и настройки `PK/Sources/DatabaseGrid/Cells/{Relation,Rollup}Cell.swift`, `PropertySettings/{RelationSettings,RollupSettings}.swift` («Связана с», «Лимит», «Ответное свойство», «Связь → Свойство → Вычислить»), окно выбора строк цели (T089)
- [ ] T093 [US4] Состояния галереи: настройки новой связи, окно выбора с выбранными, ячейка связи, настройки сводки и меню вычислений — в обеих темах; сверка с Notion
- [ ] T094 [US4] Живая проверка двух Mac `scripts/vm/sync-live-check.sh` (свой сервер в виртуальном Mac): шаги 1–3 quickstart.md; затронутые тесты зелёные; замер правки с пересчётом сводки; запись в quickstart.md; коммит

**Checkpoint**: US4 работает и проверяется сама.

---

## Phase 9: User Story 6 — Шаблоны строк базы (Priority: P6) — волна D, агент «Шаблоны»

**Goal**: «Создать ▾», шаблоны базы, по умолчанию, относительные даты.

**Independent Test**: spec, US6.

### Tests for User Story 6

- [ ] T095 [P] [US6] `PK/Tests/DatabasesTests/RowTemplateInstantiationTests.swift` (подменённые часы): новый шаблон, по умолчанию, дублировать, удалить; строка по шаблону — значения, связи, иконка, обложка, вид, блоки, подстраницы; «Сегодня» / «Сейчас» у даты и «@сегодня» в теле — момент создания; значения фильтра поверх шаблона; правка шаблона не меняет прежние строки; шаблоны строк не в таблице, поиске, разделе «Шаблоны» 003
- [ ] T096 [P] [US6] XCUITest `UITests/RowTemplatesTests.swift`: сценарии spec, US6

### Implementation for User Story 6

- [ ] T097 [US6] `PK/Sources/Databases/RowTemplates/` (создать, по умолчанию, строка по шаблону через `PageBranchCopier` 003 + ячейки и связи) (T095)
- [ ] T098 [US6] «Создать ▾» в `PK/Sources/DatabaseViewBar/NewRowMenu.swift`, правка шаблона по центру с янтарной полосой, «Быстрый выбор» в окне даты шаблона, строки шаблонов базы на пустой странице строки (место 003 `TemplateRows`) (T096)
- [ ] T099 [US6] Состояния галереи: «Создать ▾» пустой и с шаблонами, меню шаблона, правка шаблона, «Быстрый выбор» даты — в обеих темах; сверка с Notion; затронутые тесты зелёные; коммит

**Checkpoint**: US6 работает и проверяется сама.

---

## Phase 10: Сквозное (этап 8) — волна D, агент «Сквозное»

**Goal**: поиск страниц по значениям, версии строк со значениями, копия и перенос баз и строк, починка ID.

- [ ] T100 [P] [X] `PK/Tests/PageSearchTests/PageSearchDatabaseTests.swift`: строка находится по названию, телу и текстовому значению; путь «Родитель / … / База»; шаблоны и корзина — нет
- [ ] T101 [P] [X] `PK/Tests/PageVersionsTests/RowVersionTests.swift`: снимок версии 2 с ячейками и связями; правка ячейки ставит в очередь снимка; восстановление возвращает значения с ⌘Z; снимок версии 1 читается
- [ ] T102 [P] [X] `PK/Tests/DatabasesTests/DatabaseCopyMoveTests.swift` по spec, Edge Cases: «Дублировать» базу (схема, виды, строки, шаблоны, связи на ту же базу односторонне, своя база — на копию), строку в другую базу (совпавшие свойства — значения, остальные — ⌘Z), строку в страницу (предупреждение), страницу в базу (пустые свойства), удалить базу — вернуть со связями
- [ ] T103 [P] [X] `PK/Tests/SyncTests/UniqueIdRepairTests.swift`: два клиента без связи создают строки с одним номером — после встречи номера разные, перенумерация сходится
- [ ] T104 [X] Код: `PK/Sources/PageSearch/` (выдача и путь), `PK/Sources/PageVersions/PageSnapshot.swift` и восстановление, копия и перенос в `PK/Sources/NotesCore/Tree/PageTreeOperations+{Duplicate,MoveBlocks}.swift` и `Databases/Operations/DatabaseOperations+Copy.swift`, починка в `Databases/UniqueIds.swift` (T100–T103)
- [ ] T105 [X] Затронутые тесты зелёные; замер перехода и поиска на эталоне с базами; коммит

---

## Phase 11: Схема из Notion по ключу (этап 9, Q3) — волна D, агент «Схема Notion»

**Только если Юрий подтвердит Q3; иначе фаза снимается, а FR-339 и R19 убираются из документов.** Ключ — по skill `secret-handoff`, в чат не попадает.

- [ ] T106 [P] [Q3] `PK/Tests/NotionSchemaFetchTests/SchemaMappingTests.swift` на сохранённых ответах API (без сети): типы, форматы, варианты с цветами, группы статусов, связи с парой, сводки, перевод формул Notion в язык MyNotion, неподдержанное — строка отчёта
- [ ] T107 [Q3] `PK/Sources/NotionSchemaFetch/` (`URLSession`, только `GET`, ключ в Связке ключей), наложение схемы на импорт US7 до записи, кнопка «Дочитать схему из Notion» и подсказка доступа в `App/Settings/NotionImportView.swift` (T106)
- [ ] T108 [Q3] Живая проверка: образец T057 + ключ Юрия — схема дочитана, формулы работают; без сети и без доступа — импорт по CSV с причиной в отчёте; коммит

---

## Phase 12: Polish (этап 10) — волна E, агент «Итог»

- [ ] T109 `PK/Tests/DatabasesTests/DatabaseNoLossTests.swift` (SC-310): «выгрузить → импортировать», «сменить тип → ⌘Z», «удалить свойство → вернуть», «удалить базу → вернуть» на эталоне — значения и связи как в начале
- [ ] T110 [P] `PK/Tests/SyncTests/SyncConvergenceTests.swift` (два клиента, поддельный сервер) дополнить базами: все сущности v4, одновременные правки ячеек, вариантов, связей, видов; Mac с форматом 3 — «Обновите MyNotion»
- [ ] T111 Живая проверка двух Mac `scripts/vm/sync-live-check.sh` (свой сервер в виртуальном Mac, не боевой) по шести шагам quickstart.md; итоги и снимки — в quickstart.md
- [ ] T112 Галерея целиком в обеих темах; главный агент зовёт проверяющего галереи: сверка с `visual-reference/` и живым Notion (одним замком, на подстранице «MyNotion — базы 004»); находки — исполнителю этой фазы
- [ ] T113 Главный агент зовёт ревьюера кода (весь дифф 004 против `main`); находки — исполнителю этой фазы; после правок — затронутые тесты
- [ ] T114 Полный прогон тестов один раз: `swift test` и все UI-тесты в виртуальном Mac; красные — чинить и повторить затронутые
- [ ] T115 Полные замеры (quickstart.md, вся таблица) в виртуальном Mac, Release, со снимками отрисовки; переход и вкладки — три прогона, выбросы отделить
- [ ] T116 Сборка Release; переход базы v8 → v9 на копии реальной базы в виртуальном Mac; README: модули 004
- [ ] T117 Итог для Юрия: что сделано, цифры замеров, три решения по умолчанию (Q1–Q3) — подтвердить или поменять

---

## Dependencies & Execution Order

### Волны и агенты (не больше трёх одновременно, каждый в своём git worktree от `004-databases-core`)

| Волна | Агент 1 | Агент 2 | Агент 3 | Старт |
|-------|---------|---------|---------|-------|
| **A** | Фундамент: фазы 1–2 (T001–T030) | — | — | сразу |
| **B** | US1 «Таблица»: фаза 3 (T031–T045) | US5 «Формулы»: фаза 4 (T046–T056) | US7 «Импорт»: фаза 5 (T057–T064) | после T030 |
| **C** | US2 «Типы»: фаза 6 (T065–T075) | US3 «Вид»: фаза 7 (T076–T085) | US4 «Связи»: фаза 8 (T086–T094) | после вливания B |
| **D** | US6 «Шаблоны»: фаза 9 (T095–T099) | «Сквозное»: фаза 10 (T100–T105) | «Схема Notion»: фаза 11 (T106–T108), если Q3 | после вливания C |
| **E** | Polish: фаза 12 (T109–T117) | — | — | после вливания D |

Модели агентов — plan.md, «Этапы». Длинная цепочка: главный агент ставит страховочный heartbeat раз в 15 минут (с `expiresIn`) и снимает его в конце.

### Почему этапы одной волны независимы (не правят одни файлы)

- **A** один: все общие файлы (`SchemaMigrations.swift`, `NotesTransaction.swift`, `RowMapping.swift`, `Block.swift`, `SyncPayload.swift`, `ChangeMerger.swift`, `RemoteChangeApplier.swift`, `SyncSnapshot.swift`, `PageOutlineDataSource.swift`, `Package.swift`, `project.yml`, модели типов, реестры, `DatabaseOperations.swift`, `OptionChip.swift`) правятся здесь.
- **B**: US1 — `DatabaseGrid/` (кроме `Cells/FormulaCell.swift` и `PropertySettings/FormulaEditor/`), `DatabaseRowPage/`, `Databases/Operations/DatabaseOperations+{Schema,Rows,Cells}.swift`, `Databases/UniqueIds.swift`, `PageEditor/BlockKinds/Database.swift`, `App/MainWindow/DatabasePageHost.swift`; US5 — `Formulas/`, `Databases/Computation/`, `DatabaseGrid/Cells/FormulaCell.swift`, `DatabaseGrid/PropertySettings/FormulaEditor/`; US7 — `MarkdownExport/DatabaseExport/`, `NotionImport/{NotionDatabaseReader,DatabaseSchemaImport}.swift`, `NotionImport/Fixtures/NotionDatabases/`, `App/Settings/NotionImportView.swift`. **Пересечения**: `App/MainWindow/MainWindowModel.swift` (US1 — открыть базу и строку; US7 — выгрузка базы), `UIGallery/GalleryCatalog.swift` и генератор (свои строки в конец списков). Вливать US1 → US5 → US7; конфликты решает главный агент.
- **C**: US2 — `DatabaseGrid/Cells/{Select,MultiSelect,Status,Date,Files}Cell.swift`, `DatabaseGrid/PropertySettings/{Select,Status,Number}Settings.swift`, `Databases/Operations/DatabaseOperations+Options.swift`, `App/Notifications/ReminderNotifications.swift`; US3 — `DatabaseViewBar/`, `DatabaseGrid/{Grouping,Calculations}/`, `DatabaseGridView.swift` (раскладка групп), `DatabaseGrid/PropertyMenu/` (свои пункты-файлы), `Databases/Operations/DatabaseOperations+Views.swift`, `Databases/ViewQuery/NewRowDefaults.swift`; US4 — `DatabaseGrid/Cells/{Relation,Rollup}Cell.swift`, `DatabaseGrid/PropertySettings/{Relation,Rollup}Settings.swift`, `Databases/Operations/DatabaseOperations+Relations.swift`, `Databases/Computation/Rollups.swift`. **Пересечения**: `Databases/Computation/ComputationHook.swift` — только US4 (регистрирует сводки); `DatabaseGridView.swift` — только US3. Вливать US2 → US4 → US3.
- **D**: US6 — `Databases/RowTemplates/`, `DatabaseViewBar/NewRowMenu.swift`; Сквозное — `PageSearch/`, `PageVersions/`, `NotesCore/Tree/PageTreeOperations+{Duplicate,MoveBlocks}.swift`, `Databases/Operations/DatabaseOperations+Copy.swift`, `Databases/UniqueIds.swift`; Q3 — `NotionSchemaFetch/`, `App/Settings/NotionImportView.swift`. Пересечений нет.

### Внутри фазы

Тесты → убедиться, что красные по нужной причине → модель и операции → вид → выгрузка → галерея и замер → затронутые тесты зелёные → коммит. Полный прогон — один раз, T114.

### Вливание

Результаты волны вливаются в `004-databases-core` по одному, после каждого — затронутые тесты; конфликты решает главный агент; затем `git worktree remove`.
Проверяющих зовёт главный агент; замечания уходят тому же исполнителю (`send_agent_prompt`).

## Parallel Example: User Story 5

```text
Агент US5 пишет тесты одновременно (разные файлы):
T046 ParserTests.swift
T047 FunctionsTests.swift
T048 TypeCheckTests.swift
T049 FormulaRecomputeTests.swift
T050 UITests/FormulaEditorTests.swift
```

## Implementation Strategy

### MVP

Волна A → US1 → **стоп и проверка**: полностраничная и встроенная база с простыми типами работают, переживают перезапуск и синхронизацию; замеры 10 000 строк в норме.

### Наращивание

Волна B (US1, US5, US7) → волна C (US2, US3, US4) → волна D (US6, сквозное, Q3) → итог. Каждая фаза — работающая сборка в виртуальном Mac, коммит, результаты затронутых проверок и замеров.
Оценки — plan.md, «Этапы»: A ≈ 3,5 ч, B ≈ 5–7 ч, C ≈ 3,5–4 ч, D ≈ 2 ч, E ≈ 4 ч работы агентов; всего ≈ 18–21 ч.
Если Юрий выберет иначе: Q1 «нет» — из US3 уходят T078, итоги и перенос в T082–T084; Q2 на задачи не влияет; Q3 «нет» — снимается фаза 11.
