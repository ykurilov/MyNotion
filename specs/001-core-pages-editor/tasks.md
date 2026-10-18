---

description: "Задачи: минимальное ядро MyNotion для macOS"
---

# Tasks: Минимальное ядро MyNotion для macOS

**Input**: Design documents from `/specs/001-core-pages-editor/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Обязательны — конституция, принцип VI (TDD): тесты пишутся первыми и должны упасть по нужной причине, затем код, затем зелёные все.

**Organization**: По пользовательским историям; каждая история — законченный срез, который можно открыть и проверить.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно параллельно (другие файлы, нет зависимости от незавершённых задач)
- **[Story]**: история из spec.md (US1…US6)

## Path Conventions

- Приложение: `App/`, модули: `Packages/MyNotionKit/Sources/<Модуль>/`, тесты модулей: `Packages/MyNotionKit/Tests/<Модуль>Tests/`
- Сценарии: `UITests/`, замеры: `PerformanceTests/`, сервер: `server/`
- `PK` ниже = `Packages/MyNotionKit`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Проект собирается и запускает пустое окно.

- [x] T001 Создать `project.yml` для XcodeGen: приложение `MyNotion` (bundle id `cloud.kurilov.mynotion`, macOS 26.0, только arm64, Swift 6, строгая проверка параллелизма), цели `UITests` и `PerformanceTests`, схемы `MyNotion` (Debug) и `MyNotionPerformance` (Release), зависимость на локальный пакет `Packages/MyNotionKit`; добавить `*.xcodeproj` в `.gitignore`
- [x] T002 Создать `PK/Package.swift`: библиотеки `VisualStyle` (без зависимостей; от неё зависят `PageTree`, `PageEditor`, `PageSearch`), `NotesCore`, `PageTree`, `PageEditor`, `PageSearch`, `MarkdownExport`, `NotionImport`, `Sync` с тестовыми целями; зависимость GRDB.swift 7.x только у `NotesCore`; `PageTree`, `PageEditor`, `PageSearch`, `MarkdownExport`, `NotionImport`, `Sync` зависят от `NotesCore`, `NotesCore` — ни от кого из них
- [x] T003 Создать `App/MyNotionApp.swift` и `App/MainWindow/MainWindowView.swift`: `WindowGroup` с `NavigationSplitView` (пустая боковая панель + пустая область страницы), стандартное меню Mac; проверить `xcodegen generate && xcodebuild build -scheme MyNotion`
- [x] T004 [P] Создать `.gitignore` (DerivedData, `*.xcodeproj`, `server/node_modules`, `server/data`) и `README.md` с командами сборки из quickstart.md

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Модель записей, хранилище с миграциями и часами синхронизации, замеры. Без этого не начинается ни одна история.

**⚠️ CRITICAL**: Истории начинаются только после этой фазы.

### Тесты (сначала, должны упасть)

- [x] T005 [P] Тест гибридных часов в `PK/Tests/NotesCoreTests/HybridLogicalClockTests.swift`: монотонность при отстающих системных часах, приём чужой метки, сравнение с разрывом ничьей по id устройства, строковое представление сортируется так же, как сравнение
- [x] T006 [P] Тест дробного ключа порядка в `PK/Tests/NotesCoreTests/FractionalSortKeyTests.swift`: ключ между двумя соседями, в начало, в конец, 10 000 вставок подряд в одно место без перенумерации
- [x] T007 [P] Тест схемы и миграций в `PK/Tests/NotesCoreTests/DatabaseMigrationTests.swift`: пустая база создаётся со всеми таблицами; перед миграцией появляется `MyNotion.backup-<версия>.sqlite`; восстановление из копии возвращает исходные данные
- [x] T008 [P] Тест хранилища в `PK/Tests/NotesCoreTests/NotesStoreTests.swift`: «У страницы всегда есть хотя бы один блок (пустой абзац)»; запись Page/Block обновляет `fieldClocks` по изменённым полям; транзакция при ошибке не оставляет половину изменений

### Реализация

- [x] T009 [P] `HybridLogicalClock` в `PK/Sources/NotesCore/Clock/HybridLogicalClock.swift` (время Mac + счётчик + id устройства, R8); id устройства хранится в `UserDefaults` и создаётся один раз
- [x] T010 [P] `FractionalSortKey` в `PK/Sources/NotesCore/Ordering/FractionalSortKey.swift`
- [x] T011 Модели `Page` и `Block` в `PK/Sources/NotesCore/Model/Page.swift`, `Block.swift`, `InlineText.swift` строго по data-model.md: id UUID v7; `title` «может быть пустым; показывается «Без названия»»; `icon` «один эмодзи или пусто»; `parentId` «пусто — корень дерева; не может указывать на себя или потомка»; `kind` ∈ paragraph, heading1, heading2, heading3, bulletItem, numberedItem, checkbox, pageLink; `indent` «целое 0…8», «для заголовков всегда 0»; `isChecked` «только для checkbox»; `linkedPageId` «только для pageLink»; `InlineText` = строка + отрезки `{start, length, style}`, style ∈ bold, italic, strikethrough, code, link(url); `fieldClocks` и `textBaseClock` по data-model.md
- [x] T012 Схема и миграции GRDB в `PK/Sources/NotesCore/Storage/AppDatabase.swift`: файл `~/Library/Application Support/MyNotion/MyNotion.sqlite`, WAL; таблицы page, block, conflict, window_state, import_run, sync_account, outbox_entry; FTS5 `search_index(pageId, blockId, content)` с токенизатором `unicode61 remove_diacritics 2`; копия базы перед каждой миграцией (T007)
- [x] T013 `NotesStore` в `PK/Sources/NotesCore/Storage/NotesStore.swift`: чтение дерева без текста блоков, чтение страницы, транзакционные операции записи со штампами HLC; хук «внутри транзакции записи» для подписчиков (поиск, Sync): они пишут в ту же транзакцию, ядро от них не зависит
- [x] T014 [P] Модуль `VisualStyle` в `PK/Sources/VisualStyle/`: `Palette.swift` (цвета светлой и тёмной темы), `Typography.swift` (шрифты и строки блоков), `Metrics.swift` (колонка 720, высоты блоков, отступы, боковая панель, ручки, меню) — строго по таблицам contracts/visual-style.md; других мест с цветами и размерами в коде нет
- [x] T015 [P] Генератор эталонной базы в `PK/Sources/NotesCore/Fixtures/ReferenceLibraryGenerator.swift`: 1 000 страниц до 10 уровней, 100 000 блоков всех типов, одна страница на 1 000 блоков, кириллица и латиница; запуск флагом `--generate-reference-library <путь>` из `App/MyNotionApp.swift`; плюс страница «MyNotion — образец» с тем же содержимым, что на снимках `visual-reference/` (флаг `--generate-visual-sample`)
- [x] T016 [P] Замер запуска и памяти в `PerformanceTests/LaunchAndMemoryTests.swift`: `XCTApplicationLaunchMetric` до готовности редактора к вводу (signpost `EditorReady`), память всех процессов приложения через 10 с покоя на эталонной базе; пороги ≤ 1 с и ≤ 200 МБ — тест падает при превышении

**Checkpoint**: База, модель и замеры готовы — истории можно начинать.

---

## Phase 3: User Story 1 — Написать заметку и найти её после перезапуска (Priority: P1) 🎯 MVP

**Goal**: Создать страницу, написать абзацы, закрыть без «Сохранить», открыть — всё на месте.

**Independent Test**: Создать страницу, набрать текст, закрыть (и отдельно — убить процесс), открыть, сверить текст.

### Тесты US1 (сначала, должны упасть)

- [x] T017 [P] [US1] Тест автосохранения в `PK/Tests/NotesCoreTests/AutosaveCoordinatorTests.swift` с подменёнными часами: запись через 300 мс после последней правки, немедленная запись при уходе в фон и выходе, не позже 1 с после окончания ввода (FR-014); пишутся только изменённые поля изменённых блоков; если в базе версия блока новее `textBaseClock` — запись не затирает её, а создаёт `Conflict`
- [x] T018 [P] [US1] Тест «сто циклов» в `PK/Tests/NotesCoreTests/SaveReopenCycleTests.swift`: 100 раз — случайный текст во всех типах полей → закрыть документ и базу → открыть → полное совпадение (SC-004); в браузерном тесте T021 остаётся один живой случай
- [x] T019 [P] [US1] Тест ошибки записи в `PK/Tests/NotesCoreTests/SaveFailureTests.swift`: при отказе диска состояние «не сохранено» с причиной, текст в памяти не теряется, повторная попытка записывает его (FR-015)
- [x] T020 [P] [US1] Тест разбора абзацев в `PK/Tests/PageEditorTests/PageTextMappingTests.swift`: блоки → текст с атрибутами абзацев (id блока) → блоки без потерь; Enter делит блок, ⌫ в начале склеивает
- [ ] T021 [P] [US1] Сценарий `UITests/NoteSurvivesRelaunchTests.swift`: новая страница, название, абзац, выход, запуск — открыта та же страница с тем же текстом; второй прогон с `kill -9` через 1,5 с после набора — текст на месте (SC-004, SC-005)

### Реализация US1

- [x] T022 [US1] `PageDocument` в `PK/Sources/NotesCore/Document/PageDocument.swift`: одна живая копия страницы в памяти; `OpenDocuments` выдаёт один и тот же объект всем окнам (R5)
- [x] T023 [US1] `AutosaveCoordinator` в `PK/Sources/NotesCore/Document/AutosaveCoordinator.swift` (R4: только изменённые поля с проверкой `textBaseClock`) и состояние сохранения `SaveStatus` (сохранено / сохраняется / не сохранено + причина)
- [x] T024 [US1] Редактор в `PK/Sources/PageEditor/PageTextView.swift` и `PageTextStorageMapper.swift`: `NSTextView` на TextKit 2, абзац = блок (атрибут id блока), проверка орфографии и системное поведение текста (FR-013); правки уходят в `PageDocument`
- [x] T025 [US1] Поле названия страницы и редактор в `PK/Sources/PageEditor/PageEditorView.swift` (SwiftUI-обёртка) по contracts/visual-style.md: колонка 720 по центру, эмодзи-иконка над названием, название 40/48 жирностью 700, верхняя полоса 44 с путём «Родитель / Страница»; пустое название — «Без названия» цветом textSecondary; подсказка в пустом абзаце «Введите «/» для выбора блока»
- [x] T026 [US1] Полоса ошибки сохранения «Изменения не сохранены — <причина>. Повторяем…» в `PK/Sources/PageEditor/SaveStatusBanner.swift` (contracts/editor-interactions.md)
- [x] T027 [US1] Временный плоский список страниц и ⌘N в `App/MainWindow/MainWindowView.swift`; восстановление последней открытой страницы при запуске через `WindowState` (FR-006); signpost `EditorReady` для T016

**Checkpoint**: Рабочий блокнот с надёжным сохранением. Сборка, затронутые тесты и замеры, показ Юрию, коммит.

---

## Phase 4: User Story 2 — Разложить страницы по дереву (Priority: P2)

**Goal**: Вложенные страницы, дерево со сворачиванием, перенос, переименование, корзина.

**Independent Test**: Дерево в 3 уровня, перенос ветки, корзина и возврат, перезапуск — дерево то же.

### Тесты US2 (сначала, должны упасть)

- [x] T028 [P] [US2] Тест операций дерева в `PK/Tests/NotesCoreTests/PageTreeOperationsTests.swift`: подстраница создаётся парой «Page с parentId + блок pageLink в родителе»; перенос ветки целиком; перенос внутрь своего потомка отклоняется; удаление уводит ветку в корзину; возврат ставит на прежнее место, «если родитель исчез — в корень»; удаление навсегда оставляет надгробие (id + HLC)
- [x] T029 [P] [US2] Сценарий `UITests/PageTreeTests.swift`: 3 уровня, перетаскивание ветки, свернуть ветку, ⌘⌫ в корзину, вернуть, перезапуск — дерево и свёрнутость те же (сценарии 2.1–2.4)

### Реализация US2

- [x] T030 [US2] `PageTreeOperations` в `PK/Sources/NotesCore/Tree/PageTreeOperations.swift`: создать подстраницу, переименовать, перенести, в корзину, вернуть, удалить навсегда, очистить корзину; каждая операция — одна транзакция
- [x] T031 [US2] Боковое дерево в `PK/Sources/PageTree/PageOutlineView.swift` и `PageOutlineDataSource.swift`: `NSOutlineView` со своими строками по contracts/visual-style.md (высота 30, скругление 6, текст 14/500, выбранная строка с фоном hoverBackground, стрелка раскрытия вместо иконки при наведении, «⋯» и «+» справа при наведении, фон панели sidebarBackground), ленивые ветки, перетаскивание «на страницу — внутрь, между — рядом», запрет сброса в потомка, переименование двойным щелчком или Enter, ⌘⌫ (contracts/editor-interactions.md)
- [x] T032 [US2] Корзина в `PK/Sources/PageTree/TrashView.swift`: вернуть, удалить навсегда, очистить
- [x] T033 [US2] Заменить временный список в `App/MainWindow/MainWindowView.swift` деревом; ⇧⌘N — подстраница; сохранение свёрнутых веток и ширины панели в `WindowState`
- [x] T034 [US2] Отмена операций с деревом через `UndoManager` окна в `PK/Sources/NotesCore/Tree/PageTreeOperations.swift` (FR-012)

**Checkpoint**: Записи раскладываются по дереву. Сборка, затронутые тесты и замеры (`PerformanceTests`), галерея `--ui-gallery` и проверяющий интерфейса, показ Юрию, коммит.

---

## Phase 5: User Story 3 — Оформлять текст блоками (Priority: P3)

**Goal**: Все типы блоков, оформление в строке, меню «/», перестановка, отмена.

**Independent Test**: Страница из всех типов блоков, перестановка, чекбокс, перезапуск — всё на месте.

**Может идти параллельно с US2** (другие модули: `PageEditor` против `PageTree`).

### Тесты US3 (сначала, должны упасть)

- [x] T035 [P] [US3] Тест быстрых символов в `PK/Tests/PageEditorTests/MarkdownShortcutTests.swift`: `# `, `## `, `### `, `- `, `* `, `1. `, `[] `, `[ ] ` в начале пустой строки; ⌫ в начале не-абзаца → абзац; Enter в пустом пункте → абзац (contracts/editor-interactions.md)
- [x] T036 [P] [US3] Тест вложенности и перестановки в `PK/Tests/PageEditorTests/BlockStructureTests.swift`: Tab/⇧Tab в пределах «целое 0…8», заголовок всегда 0; ⌥⇧↑/⌥⇧↓ меняют `sortKey`; ⌘Enter переключает чекбокс
- [x] T037 [P] [US3] Тест оформления в строке в `PK/Tests/PageEditorTests/InlineStyleTests.swift`: ⌘B/⌘I/⇧⌘X/⌘E; вставка адреса поверх выделения создаёт ссылку; вставка из другого приложения оставляет текст и поддерживаемое оформление
- [x] T038 [P] [US3] Сценарий `UITests/KeyboardOnlyPageTests.swift`: ⌘N, название, Enter, `# ` заголовок, `- ` три пункта — только клавиши, укладывается в 10 с (SC-006; contracts/editor-interactions.md)
- [x] T039 [P] [US3] Сценарий `UITests/BlockEditingTests.swift`: все типы блоков, меню «/» с поиском, щелчок по чекбоксу, наведение показывает ручки «+ ⋮⋮», перетаскивание блока за «⋮⋮», ⌘Z/⇧⌘Z, перезапуск (сценарии 3.1–3.5)

### Реализация US3

- [x] T040 [US3] Отрисовка блоков в `PK/Sources/PageEditor/BlockLayoutFragment.swift`: заголовки, маркеры и номера списков, квадраты чекбоксов (щелчок переключает), отступы; маркеры не входят в текст (R2); размеры, маркеры по уровням `•` `◦` `▪`, номера `1.` `a.` `i.`, вид чекбокса, кода и ссылок — по contracts/visual-style.md
- [x] T041 [US3] Быстрые символы и смена типа в `PK/Sources/PageEditor/MarkdownShortcuts.swift`
- [x] T042 [US3] Меню «/» с поиском по названию в `PK/Sources/PageEditor/SlashCommandMenu.swift` в виде всплывающих меню из contracts/visual-style.md; Esc закрывает, оставляя `/`
- [x] T043 [US3] Ручки блока при наведении в `PK/Sources/PageEditor/BlockHandlesOverlay.swift`: слой поверх текста, «+» (добавить ниже, с ⌥ — выше) и «⋮⋮» (тянуть — переставить, щелчок — меню блока: сменить тип, удалить) у абзаца под мышью; позиции и размеры по contracts/visual-style.md; перетаскивание за «⋮⋮» — через `BlockMoveController`
- [x] T044 [US3] Вложенность, перестановка клавишами и перетаскиванием блока в `PK/Sources/PageEditor/BlockMoveController.swift`
- [x] T045 [US3] Оформление в строке, меню «Формат» (включая «Формат → Ссылка») и вставка в `PK/Sources/PageEditor/InlineFormatting.swift` и `App/MyNotionApp.swift`
- [x] T046 [US3] Блок `pageLink`: показ названия подстраницы, переход по щелчку, в `PK/Sources/PageEditor/PageLinkAttachment.swift`
- [x] T047 [US3] Единая отмена для смены типа, перестановки и вложенности в `PK/Sources/PageEditor/PageTextView.swift` (FR-012)
- [x] T048 [P] [US3] Замер отклика в `PerformanceTests/TypingAndNavigationTests.swift`: 200 нажатий в странице на 1 000 блоков и переходы между страницами на эталонной базе, p95 ≤ 50 мс через signpost; страница на 10 000 блоков прокручивается и набирается без превышения

**Checkpoint**: Полноценный редактор. Сборка, затронутые тесты и замеры (`PerformanceTests`), галерея `--ui-gallery` и проверяющий интерфейса, показ Юрию, коммит.

---

## Phase 6: User Story 4 — Найти страницу по слову (Priority: P4)

**Goal**: Поле поиска вверху боковой панели (⇧⌘F) находит страницу по слову из названия или текста.

**Independent Test**: На 1 000 страниц найти страницу по слову и открыть Enter.

### Тесты US4 (сначала, должны упасть)

- [x] T049 [P] [US4] Тест поиска в `PK/Tests/PageSearchTests/PageSearchTests.swift`: поиск по началу слова в названии и тексте, кириллица и латиница, регистр не важен, «Страницы в корзине из выдачи исключаются», индекс обновлён в той же транзакции, что и запись
- [ ] T050 [P] [US4] Сценарий `UITests/PageSearchUITests.swift`: ⇧⌘F, ввод слова, ↓, Enter открывает страницу (сценарий 4.1)

### Реализация US4

- [x] T051 [US4] Обновление `search_index` через хук транзакции ядра (та же транзакция, что запись) в `PK/Sources/PageSearch/SearchIndexer.swift`
- [x] T052 [US4] Запрос FTS5 и ранжирование (сначала совпадения в названии) в `PK/Sources/PageSearch/PageSearch.swift`
- [ ] T053 [US4] Поле поиска и список результатов вверху боковой панели в `PK/Sources/PageSearch/SidebarSearchField.swift` (вид по contracts/visual-style.md, результаты — всплывающим меню); подключение в `App/MainWindow/MainWindowView.swift`, ⇧⌘F фокусирует поле
- [ ] T054 [P] [US4] Замер в `PerformanceTests/SearchTests.swift`: ≤ 100 мс на символ по эталонной базе (SC-009)

**Checkpoint**: Поиск работает. Сборка, затронутые тесты и замеры (`PerformanceTests`), галерея `--ui-gallery` и проверяющий интерфейса, показ Юрию, коммит.

---

## Phase 7: Выгрузка в Markdown (FR-017)

**Goal**: Все записи выгружаются в папку Markdown с вложенностью. Нужна до импорта: общий разбор Markdown проверяется круговым тестом.

**Может идти параллельно с US4.**

- [ ] T055 [P] Тест выгрузки в `PK/Tests/MarkdownExportTests/MarkdownExporterTests.swift` по таблице contracts/files-import-export.md: все типы блоков и оформление, папки подстраниц, замена `/` и `:` на `-`, ` (2)` для одинаковых соседей, корзина не выгружается
- [ ] T056 `MarkdownBlockWriter` в `PK/Sources/MarkdownExport/MarkdownBlockWriter.swift` и `MarkdownExporter` в `PK/Sources/MarkdownExport/MarkdownExporter.swift` (папка `MyNotion-выгрузка-<ГГГГ-ММ-ДД>/`)
- [ ] T057 Команда меню «Выгрузить в Markdown…» (⌘⇧E) с выбором папки в `App/Settings/ExportCommand.swift`

**Checkpoint**: Записи можно забрать в обычные файлы. Сборка, затронутые тесты и замеры (`PerformanceTests`), галерея `--ui-gallery` и проверяющий интерфейса, показ Юрию, коммит.

---

## Phase 8: User Story 5 — Одни и те же записи на всех Mac (Priority: P5)

**Goal**: Правки расходятся между Mac через `mynotion.kurilov.cloud`, работают без сети, не теряются при одновременной правке.

**Independent Test**: Два клиента с локальным сервером: правка доходит, правки без связи сливаются, конфликт текста даёт выбор, 0 потерь.

**Серверная часть (T058–T067) может начаться сразу после Phase 1** — она не зависит от модулей приложения.

### Сервер: тесты (сначала, должны упасть)

- [ ] T058 [P] [US5] Создать `server/package.json` (pnpm, Node 22, Hono, better-sqlite3, Vitest, TypeScript), `server/tsconfig.json`; `pnpm install`, коммит `pnpm-lock.yaml`
- [ ] T059 [P] [US5] Контрактные тесты в `server/test/devices.test.ts`: `/devices/invite` → 201 со сроком 15 минут и одним использованием; `/devices/join` → 201 или 410; `GET /devices`; `DELETE /devices/{id}` → 204, затем 401 для этого токена; хранится только sha256 токена
- [ ] T060 [P] [US5] Контрактные тесты в `server/test/journal.test.ts`: `POST /changes` → 201 с `seq`, повтор `batchId` → 200 с тем же `seq`, больше 4 МБ → `too_large`; `GET /changes` отдаёт до 200 пачек и `hasMore`, долгое ожидание отвечает сразу при новой пачке (подменённые часы, один живой случай), `410 log_compacted` после сжатия; `/ack`; `PUT/GET /snapshot` и удаление пачек ≤ seq после подтверждения всеми активными устройствами; единый вид ошибок

### Сервер: реализация

- [ ] T061 [US5] Устройства и приглашения в `server/src/devices.ts`
- [ ] T062 [US5] Журнал, долгое ожидание, снимки и сжатие в `server/src/journal.ts`
- [ ] T063 [US5] Маршруты, авторизация `Bearer`, `/health`, лимиты тела в `server/src/app.ts`; запуск в `server/src/main.ts` (порт из `PORT`, база в `DATA_DIR`)
- [ ] T064 [US5] Команда `mynotion-sync bootstrap` (создаёт первое устройство и печатает токен один раз) в `server/src/bootstrap.ts`
- [ ] T065 [US5] `server/Dockerfile` и `server/docker-compose.yml`: том для `DATA_DIR`, `restart: unless-stopped`, проверка `/health`
- [ ] T066 [US5] Развернуть на индонезийском сервере по скиллу server-deploy: `/opt/apps/mynotion-sync`, Nginx и сертификат для `mynotion.kurilov.cloud` (`proxy_read_timeout` ≥ 35 с для долгого ожидания), ежедневная копия файла базы; гейт «прод жив»: `https://mynotion.kurilov.cloud/health` → 200
- [ ] T067 [US5] Токен первого устройства передать через secret-handoff в `~/.codex/secrets/mynotion-sync-device.env`; в чат, файлы проекта и коммиты не попадает

### Приложение: тесты (сначала, должны упасть)

- [ ] T068 [P] [US5] Тест слияния в `PK/Tests/SyncTests/ChangeMergerTests.swift` по R8: поля страницы и блока — побеждает поздний HLC; одновременная правка текста одного блока → `Conflict` с обеими версиями; перенос с петлёй отклоняется; правка страницы из корзины возвращает её и даёт уведомление; правка страницы, стёртой навсегда на другом Mac без знания о правке, возвращает её в корзину на всех Mac с уведомлением; стирание навсегда побеждает правки, сделанные до него; разное перемещение одной ветки на двух Mac сходится к одному дереву; надгробия и помеченные блоки стираются только после подтверждения всеми устройствами; применение одной пачки дважды ничего не меняет
- [ ] T069 [P] [US5] Тест шифрования в `PK/Tests/SyncTests/BatchCipherTests.swift`: ChaChaPoly, свой nonce на пачку, `deviceId` и `batchId` проверяются; подменённая пачка отвергается; `formatVersion` новее известного — пачка ждёт с сообщением «обновите MyNotion на этом Mac»
- [ ] T070 [P] [US5] Тест сходимости в `PK/Tests/SyncTests/SyncConvergenceTests.swift`: два клиента и сервер из `server/` (запуск на свободном порту, своя база); правка доходит не позже 10 с (SC-007); оба без связи правят, связь возвращается — 0 потерянных правок (SC-008); сжатие журнала и подключение третьего клиента со снимка
- [ ] T071 [P] [US5] Тест открытой страницы в `PK/Tests/SyncTests/OpenDocumentRemoteApplyTests.swift`: пришедшая правка чужого блока появляется в открытом `PageDocument` без сдвига курсора; правка блока, который сейчас набирается, становится `Conflict`; последующее автосохранение не затирает пришедшую правку (research R4, R5)
- [ ] T072 [P] [US5] Тест отключения в `PK/Tests/SyncTests/SyncToggleTests.swift`: выключение удаляет `SyncAccount` и очередь, записи не меняются, ядро работает (FR-024)

### Приложение: реализация

- [ ] T073 [US5] Очередь исходящих в `PK/Sources/Sync/Outbox.swift`: хук транзакции `NotesStore` кладёт `OutboxEntry` в той же транзакции, только если Sync включён
- [ ] T074 [US5] `BatchCipher` в `PK/Sources/Sync/BatchCipher.swift`; ключ и токен устройства в связке ключей в `PK/Sources/Sync/SyncKeychain.swift`
- [ ] T075 [US5] `ChangeMerger` в `PK/Sources/Sync/ChangeMerger.swift` и запись конфликтов в таблицу conflict
- [ ] T076 [US5] Доставка пришедших правок в открытые документы: `PageDocument.applyExternalChanges` в `PK/Sources/NotesCore/Document/PageDocument.swift` и `RemoteChangeApplier` в `PK/Sources/Sync/RemoteChangeApplier.swift`
- [ ] T077 [US5] Клиент сервера в `PK/Sources/Sync/SyncClient.swift` по contracts/sync-api.md: отправка с повтором, долгое ожидание 25 с, `/ack`, снимок при `410`, повтор с паузой при отсутствии сети
- [ ] T078 [US5] `SyncEngine` в `PK/Sources/Sync/SyncEngine.swift`: цикл отправки и получения, применение пачек, периодический снимок; состояние «готово / отправка / ошибка»
- [ ] T079 [US5] Сборщик надгробий в `PK/Sources/Sync/TombstoneCollector.swift`: стирает надгробия страниц и помеченные блоки после подтверждения всеми устройствами (`GET /devices`, `lastAckSeq`); при выключенном Sync — сразу
- [ ] T080 [US5] Подключение Mac в `App/Settings/SyncSettingsView.swift`: включить с токеном первого устройства; «Добавить Mac» показывает код (приглашение + ключ шифрования); ввод кода на втором Mac; рядом с кодом предупреждение «Код открывает все записи. Не пересылайте его в мессенджерах — введите вручную»; список устройств и отключение
- [ ] T081 [US5] Значок синхронизации внизу боковой панели в `PK/Sources/PageTree/SyncStatusBadge.swift` (FR-022)
- [ ] T082 [US5] Метка «Две версии» и окно сравнения с выбором (одна версия или обе двумя блоками) в `PK/Sources/PageEditor/ConflictResolutionView.swift`; уведомление о возврате страницы из корзины

**Checkpoint**: Записи на всех Mac. Живая проверка на двух Mac по quickstart.md. Сборка, затронутые тесты и замеры (`PerformanceTests`), галерея `--ui-gallery` и проверяющий интерфейса, показ Юрию, коммит.

---

## Phase 9: User Story 6 — Перенести записи из Notion (Priority: P6)

**Goal**: Стандартная выгрузка Notion превращается в ветку страниц с отчётом об упрощённом.

**Independent Test**: Образец выгрузки с вложенностью → дерево и текст совпадают, отчёт перечисляет упрощённое.

### Тесты US6 (сначала, должны упасть)

- [ ] T083 [P] [US6] Образец выгрузки в `PK/Tests/Fixtures/notion-export/`: 3 уровня страниц с хвостами `<32 hex>`, все поддерживаемые блоки, CSV-таблица, картинка, toggle, callout, цитата, код-блок, ссылки между страницами, вложенный ZIP
- [ ] T084 [P] [US6] Тест разбора в `PK/Tests/NotionImportTests/NotionMarkdownParserTests.swift`: поддерживаемое → блоки по таблице contracts/files-import-export.md; круговой тест «наша выгрузка → разбор → те же блоки»
- [ ] T085 [P] [US6] Тест импорта в `PK/Tests/NotionImportTests/NotionImporterTests.swift`: вложенность из путей; CSV → «Колонка: значение»; файлы → «[файл: имя]»; неподдерживаемое → абзацы с текстом; ссылки между страницами → pageLink или текст; ветка «Импорт из Notion — <дата>»; отчёт; прерванный импорт откатывает ветку; повтор с тем же `sourceFingerprint` — предупреждение до начала
- [ ] T086 [P] [US6] Замер в `PerformanceTests/NotionImportPerformanceTests.swift`: сгенерированная выгрузка на 1 000 страниц ≤ 60 с, окно отвечает во время импорта (SC-010)

### Реализация US6

- [ ] T087 [US6] Распаковка через `/usr/bin/ditto -x -k` во временную папку, включая вложенные ZIP, в `PK/Sources/NotionImport/NotionExportUnpacker.swift`
- [ ] T088 [US6] Разбор Markdown-подмножества Notion в `PK/Sources/NotionImport/NotionMarkdownParser.swift`
- [ ] T089 [US6] `NotionImporter` в `PK/Sources/NotionImport/NotionImporter.swift`: обход папок, CSV, ссылки, транзакция на ветку, `ImportRun` со статусами running, finished, failed, ход работы
- [ ] T090 [US6] Команда «Импорт из Notion…», прогресс и окно отчёта в `App/Settings/NotionImportView.swift`

**Checkpoint**: Переезд из Notion. Сборка, затронутые тесты и замеры (`PerformanceTests`), галерея `--ui-gallery` и проверяющий интерфейса, показ Юрию, коммит.

---

## Phase 10: Polish & Cross-Cutting Concerns

- [ ] T091 Светлая и тёмная тема: снимки главного окна, дерева, редактора, полос и окна конфликта в `UITests/AppearanceSnapshotTests.swift` (FR-028)
- [ ] T092 Сверка с образцом Notion в `UITests/VisualReferenceTests.swift`: открыть страницу «MyNotion — образец» (`--generate-visual-sample`), окно 1440×900, снимки в обеих темах в `specs/001-core-pages-editor/visual-reference/mynotion-*.png`; по рамкам элементов проверить цифры contracts/visual-style.md (колонка 720 по центру, высоты блоков, строка дерева 30, позиции ручек) с допуском 1 pt; показать Юрию пары снимков «Notion / MyNotion» (FR-031, SC-012)
- [ ] T093 Несколько окон: одна страница в двух окнах, набор в обоих — текст общий, без потерь, в `UITests/MultiWindowTests.swift` (FR-029)
- [ ] T094 Крайние случаи из spec: глубокое дерево 10+ уровней читаемо, нет места на диске (подменённый отказ записи) — предупреждение без потери текста; дополнить `UITests/PageTreeTests.swift` и `PK/Tests/NotesCoreTests/SaveFailureTests.swift`
- [ ] T095 Полный прогон: `xcodebuild test -scheme MyNotion`, `xcodebuild test -scheme MyNotionPerformance -configuration Release` на эталонной базе, `pnpm test` в `server/`; результаты замеров записать в `specs/001-core-pages-editor/quickstart.md`
- [ ] T096 Сборка Release, установка в `/Applications/MyNotion.app`, ручная проверка по quickstart.md

---

## Dependencies & Execution Order

### Фазы

- **Setup (1)** → **Foundational (2)** → истории.
- **US1 (3)** — после фазы 2. MVP.
- **US2 (4)** и **US3 (5)** — после US1, параллельно друг другу.
- **US4 (6)** и **Выгрузка (7)** — после US2 и US3, параллельно друг другу.
- **US5 (8)**: сервер (T058–T067) — сразу после фазы 1, параллельно всему; приложение (T068–T082) — после US2 и US3.
- **US6 (9)** — после US3 и выгрузки (общий круговой тест Markdown).
- **Polish (10)** — после всех.

### Внутри истории

Тесты → убедиться, что красные по нужной причине → модели и логика → интерфейс → зелёные все → коммит.

### Параллельные агенты (не больше трёх, каждый в своём git worktree)

| Окно | Агент A | Агент B | Агент C |
|------|---------|---------|---------|
| После фазы 2 | US1 | Сервер T058–T065 | — |
| После US1 | US2 | US3 | Сервер T066–T067 (деплой) |
| После US2+US3 | US4 | Выгрузка | US5-приложение |
| После выгрузки | US6 | — | — |

## Parallel Example: User Story 3

```text
Агент пишет одновременно (разные файлы):
T035 MarkdownShortcutTests.swift
T036 BlockStructureTests.swift
T037 InlineStyleTests.swift
T039 BlockEditingTests.swift
```

## Implementation Strategy

### Ветка

Вся стройка — в ветке `001-core-pages-editor` (параллельные агенты — в своих worktree от неё); в `main` — после T095.

### MVP

1. Фазы 1–2 → US1 → **стоп и проверка**: Юрий пишет заметки, всё сохраняется, замеры запуска и памяти в норме.

### Наращивание

US2 + US3 → поиск и выгрузка → синхронизация → импорт из Notion. Каждый срез — работающая сборка и коммит; замеры бюджета прогоняются после правок, влияющих на скорость, и в конце этапа.
