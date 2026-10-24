---

description: "Задачи: управление MyNotion из командной строки для агентов"
---

# Tasks: Управление MyNotion из командной строки для агентов

**Input**: Design documents from `/specs/005-cli-control/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Обязательны (конституция VI, TDD). В каждой фазе тесты пишутся первыми и должны упасть по нужной причине (`not_implemented`, нет типа или функции), затем код, затем зелёные все затронутые.

**Organization**: фаза = этап из plan.md. Этап 1 (Phase 1–2) идёт один. Волна A — фазы US1, US2, US3 параллельно, каждая в своём worktree. Волна B — US5, US6 и после вливания US1 — US4. Не больше трёх агентов сразу. Итог — Phase 9.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно параллельно внутри фазы (другие файлы, нет зависимости от незавершённых задач)
- **[Story]**: история из spec.md (US1…US6)

## Path Conventions

- `PK` = `Packages/MyNotionKit`; модули — `PK/Sources/<Модуль>/`, тесты — `PK/Tests/<Модуль>Tests/`; приложение — `App/`; команда и скилл — `Tools/`.
- Сборки и тесты — только на iMac через `imac-run` (skill imac). На основном Mac ничего не собирать и не запускать. Модули: `cd PK && imac-run --no-fallback --wait 1800 --no-setup -- swift test --jobs 4 --filter '<Цели>'`. Сборка приложения и живые проверки: `scripts/imac/run-on-imac.sh run|lock …`.
- Параллельный этап работает только в своём worktree и правит только свои файлы (plan.md, «Этапы и параллельность»). Общие файлы этапа 1 — `Package.swift`, `project.yml`, `Catalog/*` чужих групп, `HandlerRegistry.swift`, `SKILL.md` — не трогать. Нужен новый флаг — правка только своего `Catalog/<Группа>.swift`.
- Долгий прогон ждать внутри хода: PID в файл и `kill -0`, или строка итога в логе; не `pgrep -f`. Ход заканчивается только итогом фазы.
- Проверки по размеру: в фазах — только тесты своей группы и одна живая команда. Полный прогон всех тестов и сквозной сценарий — один раз, в Phase 9.

---

## Phase 1: Setup — этап 1 «Основа»

**Purpose**: все новые модули, цели и тестовые цели сразу, чтобы параллельные этапы только добавляли файлы

- [x] T001 В `PK/Package.swift` добавить продукты, цели и тестовые цели: `ControlProtocol` (без зависимостей), `ControlServer` (ControlProtocol), `ControlClient` (ControlProtocol), `ControlCommands` (ControlProtocol, NotesCore, Databases, Formulas, PageVersions, PageSearch, Attachments, MarkdownExport, NotionImport, Navigation, PageMarkdown), `PageMarkdown` (NotesCore, MarkdownExport, NotionImport, Attachments); пустые папки по plan.md («Source Code»)
- [x] T002 В `project.yml` добавить цель `mynotion` (type `tool`, macOS 26, sources `Tools/mynotion`, зависимости ControlProtocol и ControlClient); вложить её в `MyNotion.app/Contents/Helpers/` (сборочная зависимость с копированием в Helpers); подключить к приложению ControlServer и ControlCommands; добавить новые тестовые цели в схему `MyNotion`; проверить на iMac `scripts/imac/run-on-imac.sh run --release --help`, что в пакете есть `Contents/Helpers/mynotion`

---

## Phase 2: Foundational — этап 1 «Основа»

**Purpose**: протокол, каталог всех команд, сервер, клиент, исполнитель, пакет, версия «до правки агента», кодеки, указатели, старт в приложении, скилл и установка. ⚠️ Ни одна история не начинается до конца фазы.

### Тесты основы (до кода, красные)

- [x] T003 [P] `PK/Tests/ControlProtocolTests/CatalogTests.swift`: в каталоге есть каждая команда из contracts/commands.md (список строк из файла контракта — фикстура), у каждой — summary, пример, тип R/W и `batchable` как в таблице; имена уникальны; `commands --json` стабилен (снимок)
- [x] T004 [P] `PK/Tests/ControlProtocolTests/ArgumentParserTests.swift`: позиционные и флаги, `--flag=value`, повтор флага, `-` как stdin, неизвестный флаг → `invalid_argument` с ближайшим вариантом, нет обязательного → `missing_argument`, взаимоисключающие (`--after`/`--first`), `--help` на трёх уровнях без приложения
- [x] T005 [P] `PK/Tests/ControlProtocolTests/ProtocolCodingTests.swift`: запрос, ответ, ход, ошибка — JSON по contracts/protocol.md; кадр — одна строка, `\n` внутри строк экранирован; запрос > 64 МБ — отказ; каждый `ControlErrorCode` имеет группу и код выхода по таблице (2, 3, 4, 5, 1)
- [x] T006 [P] `PK/Tests/ControlServerTests/SocketServerTests.swift` (временный сокет): файл `0600`; подключение — запрос — ответ; чужой uid (подставная `PeerCredentials`) — закрыто без ответа; устаревший файл сокета заменяется; живой сокет другой копии не трогается; 20 клиентов сразу — ответы не перепутаны; разрыв клиентом во время выполнения — сервер не падает
- [x] T007 [P] `PK/Tests/ControlClientTests/ClientTests.swift` (подставной «запускатель» и временный сокет): сокета нет → запуск `open -g <пакет>` и повторы каждые 100 мс до `--launch-timeout`, затем `app_not_ready`; `--no-launch` → `app_not_running`, код 5; процесс приложения есть, а сокета нет (окно восстановления, переход базы) → `app_not_ready` с причиной; `--timeout` истёк → `timeout`; приложение закрыло связь посреди ответа → `app_disconnected`; другой `protocol` → `version_mismatch` с обеими версиями; путь пакета — из собственного пути после разыменования ссылки; `--human` печатает ✓/✗ и подсказку в stderr; код выхода по группе ошибки
- [x] T008 [P] `PK/Tests/ControlCommandsTests/ExecutorTests.swift` (временная база, настоящие операции, подставные хост и окно): неизвестная команда → `unknown_command`; команда без обработчика → `not_implemented`; записи идут строго по одной (две долгие записи не пересекаются); чтение не ждёт записи; проверка аргументов до выполнения; журнал — строка на команду без текста записей (подставной `CommandLog`); списки без `--limit` — 200 записей и `nextCursor`, `--limit 1001` → `invalid_argument` (FR-409)
- [x] T009 [P] `PK/Tests/ControlCommandsTests/BatchTests.swift`: три шага, ошибка на третьем → `batch_failed` с номером шага, данные как до пакета (страницы, блоки, ячейки базы); `"$1.id"` подставляется; команда без отмены в пакете → `not_batchable` до выполнения
- [x] T010 [P] `PK/Tests/ControlCommandsTests/AgentCheckpointTests.swift` (подменённые часы): первая правка страницы агентом снимает версию с `agent`; вторая через 5 мин — нет, через 11 мин — да; разные страницы — свои версии; прореживание `VersionPruning` хранит такие версии; старые версии без поля читаются
- [x] T011 [P] `PK/Tests/ControlCommandsTests/LocatorTests.swift`: id, префикс ≥ 8 знаков, `current` (подставное окно), путь с `/` и `\/`, регистр и `ё/е`; неоднозначный путь → `ambiguous_page` с кандидатами; корзина → `page_in_trash`, с `--include-trashed` находится; блок не той страницы → `wrong_page`
- [x] T012 [P] `PK/Tests/ControlCommandsTests/CodecTests.swift`: `decode(encode(x)) == x` для страницы, блока каждого `BlockKind` (contracts/block-json.md), каждого `PropertyKind` ячейки, фильтра И/ИЛИ с вложенной группой, сортировки и группировки с именами свойств ↔ id; оформление строки (жирный, курсив, зачёркнутый, код, подчёркнутый, цвет текста и фона, ссылка, упоминание страницы и даты) в Markdown-записи и в `rich` (FR-417); неверное значение ячейки → `invalid_value` с `property`, `type`, `expected`, `example`

### Код основы

- [x] T013 `PK/Sources/ControlProtocol/`: `ControlRequest`, `ControlResponse` (+ ход), `ControlError`, `ControlErrorCode` (закрытый список contracts/protocol.md с группой), `LineFraming` (T005)
- [x] T014 `PK/Sources/ControlProtocol/CommandSpec.swift`, `CommandCatalog.swift`, `ArgumentParser.swift` и `Catalog/{Service,Pages,Blocks,Databases,Library,Window,Transfer}.swift` — весь каталог contracts/commands.md с аргументами, справкой, примером и номером этапа (T003, T004)
- [x] T015 `PK/Sources/ControlServer/` (`ControlSocketPath` — путь по research R1, `$TMPDIR`-запасной при длине > 100 байт; `ControlSocketServer` — `umask 077`, `bind`, `listen`, `DispatchSource`, `getpeereid`; `PeerCredentials`) (T006)
- [x] T016 `PK/Sources/ControlClient/` (`SocketClient`, `AppLauncher` с `open -g`, `HumanOutput`, `ExitCode`) и `Tools/mynotion/main.swift` — разбор → запрос → печать (T007)
- [x] T017 `PK/Sources/ControlCommands/` каркас: `ControlHost`, `WindowControl` (протоколы по data-model.md), `CommandSession` (свой `UndoManager`, агент, предупреждения, затронутые страницы), `WriteLock`, `CommandExecutor`, `HandlerRegistry` (все группы, у каждой свой файл `Handlers/<Группа>Handlers.swift` с заглушками `not_implemented`), `CommandLog` (`os.Logger`, category `control`) (T008)
- [x] T018 `PK/Sources/ControlCommands/BatchRunner.swift` — шаги под одним замком, откат своей отменой, `$N.путь` (T009)
- [x] T019 `PK/Sources/ControlCommands/AgentEditCheckpoint.swift`; поле `agent: String?` в `PK/Sources/PageVersions/VersionDiff.swift` (`VersionSummary`), признак в `VersionStamp` и хранение в `VersionPruning.swift`; подпись «до правки агента (имя)» в окне истории `App/MainWindow/VersionHistory/` (T010)
- [x] T020 [P] `PK/Sources/ControlCommands/Locators/` (`PageLocator`, `BlockLocator`, `DatabaseRefs`) (T011)
- [x] T021 [P] `PK/Sources/ControlCommands/Codecs/` (`PageJSON`, `BlockJSON`, `CellValueJSON`, `ViewJSON`) по contracts/block-json.md (T012)
- [x] T022 `PK/Sources/ControlCommands/Handlers/ServiceHandlers.swift`: `app status`, `commands`, `batch`
- [x] T023 `App/Control/ControlBootstrap.swift` (старт сервера в конце `openLibrary` в `App/MyNotionApp.swift`, после переходов базы и отката прерванного импорта; при окне восстановления — после его закрытия; остановка в `applicationShouldTerminate`), `App/Control/AppControlHost.swift` (хост поверх `PagesLibrary`: колбэки операций → `treeDidChange`, `refreshAfterDirectWrite` = шаги `remoteChangesApplied`), заглушки `App/Control/AppWindowControl.swift` и `App/Control/AppTransferControl.swift`
- [x] T024 Скилл `Tools/mynotion-skill/SKILL.md`: где команда, указатели страниц, JSON и коды ошибок, `--agent`, версия «до правки агента», ограничения (нет настроек, `--force`), журнал `log show --predicate 'category == "control"'`; ссылки на `references/{pages,blocks,databases,library,window,transfer}.md` (пустые заготовки «будет на этапе N»)
- [x] T025 `scripts/install-cli.sh` по research R14: Release-сборка с iMac (`imac-run --fetch`), копия в `/Applications` только если приложение не запущено (иначе сообщение и выход без изменений), флаг `--target <папка>` для установки на iMac в `~/Applications`; ссылка `~/.local/bin/mynotion` → `…/MyNotion.app/Contents/Helpers/mynotion`; копия скилла в `~/.agents/skills/mynotion`; проверка видимости скилла Codex, при надобности — ссылка `~/.codex/skills/mynotion`; `skill-doctor.sh`
- [x] T026 Затронутые тесты зелёные на iMac. Живая проверка на iMac (Release): приложение закрыто → `mynotion app status` поднимает его без захвата фокуса (`lsappinfo front`), ≤ 4 с; `mynotion page tree` → `not_implemented`; права сокета `0600`. Замер запуска и памяти в покое против 004 (quickstart, «Замеры») — в `quickstart.md`. Коммит «005 этап 1: основа»

**Checkpoint**: протокол закреплён, каталог полный, команда доходит до приложения. Волна A может начинаться.

---

## Phase 3: User Story 1 — Агент читает и пишет страницы (Priority: P1) 🎯 MVP — этап 2, волна A

**Goal**: дерево, чтение и запись Markdown, создание, переименование, перенос, дублирование, корзина

**Independent Test**: spec US1 «Independent Test»; на iMac — шаги 1–3 и 11 сценария A (quickstart)

### Тесты (до кода)

- [ ] T027 [P] [US1] `PK/Tests/PageMarkdownTests/RoundTripTests.swift`: для каждой страницы эталона 001–004 «прочитать → записать → прочитать» даёт тот же Markdown (SC-404); фикстура `meeting.md` (заголовки, списки с вложенностью, задачи, код с языком, цитата, выноска, раскрывающийся список, таблица GFM, формула, разделитель, ссылка на страницу)
- [ ] T028 [P] [US1] `PK/Tests/PageMarkdownTests/PlainMarkdownTests.swift`: режим `.plainMarkdown` — первая `# ` не становится названием; HTML-блок и сноска → абзац + предупреждение с номером строки; картинка по локальному пути → вложение, по `https` → блок-картинка со ссылкой; пустой Markdown → пустая страница
- [ ] T029 [P] [US1] `PK/Tests/NotionImportTests/ParsedBlockConverterTests.swift`: вынесенный конвертер даёт те же блоки, что прежний импорт, на всех фикстурах `NotionImportTests/Fixtures` (сравнение до и после выноса)
- [ ] T030 [P] [US1] `PK/Tests/ControlCommandsTests/PageCommandsTests.swift`: `page tree` (глубина, ветка, без корзины и шаблонов строк, `--limit/--cursor`), `get`, `read` markdown и json, `create` (в корне, под родителем, `--after`, `--icon`, `--markdown`, `--template` — как создание из шаблона в окне), `write` (замена, версия «до правки агента»), `append` (в конец, после блока), `rename`, `move` (в свою ветку → `cannot_move`), `duplicate`, `trash`/`restore`, `layout`, `trash list`, `trash delete`/`empty` без `--force` → `force_required`; каждая правка возвращает объект целиком (FR-431); после `create`/`write` есть запись в очереди синхронизации (`Outbox`), новый текст находит `PageSearch`, ссылка на страницу видна в обратных ссылках (FR-403, SC-405)
- [ ] T031 [P] [US1] `PK/Tests/ControlCommandsTests/OpenDocumentEditTests.swift` (SC-403): страница открыта (`OpenDocuments.open`), в документе незаписанная правка «Юрия» → `page append` агента → в документе и на диске обе правки; 1 000 чередований ввода и команд — ни одна правка не потеряна

### Код

- [ ] T032 [US1] Вынести перевод `ParsedBlock → BlockDraft` из `NotionImporter.blocks(for:in:…)` в публичный `PK/Sources/NotionImport/ParsedBlockConverter.swift`, импорт Notion — через него; флаг разбора `.plainMarkdown` в `NotionMarkdownParser` (T029)
- [ ] T033 [US1] `PK/Sources/PageMarkdown/PageMarkdownReader.swift` (через `MarkdownBlockWriter`) и `MarkdownBlocksBuilder.swift` (разбор → черновики блоков, вложения через `AttachmentStore.importFile`, предупреждения) (T027, T028)
- [ ] T034 [US1] `PK/Sources/ControlCommands/Handlers/PageHandlers.swift`: все команды `page …` и `trash …` через `PageTreeOperations` сессии, `MainWindowModel.createPage`-эквивалент для корня, запись содержимого через `OpenDocuments` → `PageDocument.replaceBlocks` → сохранение до ответа (research R3) (T030, T031)
- [ ] T035 [US1] `Tools/mynotion-skill/references/pages.md`: сценарии «найти и прочитать», «создать с Markdown», «дописать», «переложить», «вернуть из корзины», «откатить правку агента»; каждый пример выполнен на iMac
- [ ] T036 [US1] Затронутые тесты зелёные (`PageMarkdownTests`, `NotionImportTests`, `ControlCommandsTests`); живая проверка шагов 1–3 и 11 сценария A на iMac со снимком окна; замер запуска и памяти в покое против прошлого этапа (quickstart, «Замеры», конституция II); коммит

**Checkpoint**: MVP — агент читает и пишет страницы.

---

## Phase 4: User Story 2 — Блоки, иконки, обложки (Priority: P2) — этап 3, волна A

**Goal**: точечная правка блоков любого вида, иконка, обложка

**Independent Test**: spec US2 «Independent Test»; шаги 5–6 сценария A

### Тесты (до кода)

- [ ] T037 [P] [US2] Перенести тесты правил отступа и переноса из `PK/Tests/PageEditorTests/` в `PK/Tests/NotesCoreTests/BlockStructureTests.swift` без изменения проверок; должны упасть, пока функций нет в NotesCore
- [ ] T038 [P] [US2] `PK/Tests/ControlCommandsTests/BlockCommandsTests.swift`: `block kinds`; `insert` каждого вида из contracts/block-json.md в каждую позицию (`--first/--last/--after/--inside`); `update` текста (Markdown строки и `rich`), свойств вида, смена вида; `move` с вложенными; `indent`/`outdent` по правилам окна (заголовок, предел 8); `check`/`uncheck`; `expand`/`collapse`; `delete`; `move-to-page`; неизвестный вид → `invalid_argument` со списком; `tableRow` на вход → `invalid_argument`
- [ ] T039 [P] [US2] `PK/Tests/ControlCommandsTests/IconCoverCommandsTests.swift`: `page icon` эмодзи и `--remove`; `page cover --gallery` (неизвестное имя → список), `--file` (вложение), `--offset`, `--remove`, `--list`

### Код

- [ ] T040 [US2] Перенести `indenting`, `moving`, `movedGroup`, `subtreeEnd`, `headingIndent` в `PK/Sources/NotesCore/Document/BlockStructure.swift` (публичные); `PK/Sources/PageEditor/BlockMoveController.swift` вызывает их (T037)
- [ ] T041 [US2] `PK/Sources/ControlCommands/Handlers/BlockHandlers.swift`: правки через `OpenDocuments` → `PageDocument.apply/replaceBlocks/setText`, правила из `BlockStructure`, перенос на страницу — `PageTreeOperations.moveBlocks`, иконка и обложка — `setIcon`, `setCover`, `setCoverOffset` (T038, T039)
- [ ] T042 [US2] `Tools/mynotion-skill/references/blocks.md`: прочитать блоки JSON-ом, вставить после, поправить текст, отметить задачи, перенести; иконка и обложка; примеры выполнены на iMac
- [ ] T043 [US2] Затронутые тесты зелёные (`NotesCoreTests`, `PageEditorTests`, `ControlCommandsTests`); живая проверка шагов 5–6 сценария A со снимком окна (правка видна ≤ 1 с, курсор Юрия в другом блоке не сбит); замер запуска и памяти в покое против прошлого этапа (quickstart, «Замеры», конституция II); коммит

---

## Phase 5: User Story 3 — Базы данных (Priority: P3) — этап 4, волна A

**Goal**: всё 004 командами: схема, свойства, варианты, строки, ячейки, связи, формулы, виды, строки вида

**Independent Test**: spec US3 «Independent Test»; шаг 7 сценария A

### Тесты (до кода)

- [ ] T044 [P] [US3] `PK/Tests/ControlCommandsTests/Databases/SchemaCommandsTests.swift`: `db create` встроенная и на всю страницу; `db schema`; `db prop add` каждого типа 004 с `--config`; `update` (формат числа, лимит связи, «показать в другой базе», сводка, `--formula` с ошибкой → `invalid_formula` с местом); `type` с переводом значений; `move`, `duplicate`, `delete`, `restore`; `db option add/rename/color/move/delete` и группы статуса
- [ ] T045 [P] [US3] `PK/Tests/ControlCommandsTests/Databases/RowCommandsTests.swift`: `db row add` одной и пачкой 1 000 (ошибка в одной — не записана ни одна), новый вариант → `option_created`, неверный тип → `invalid_value`; `update`, `cell set` (`null` — очистить), вычисляемые → `read_only_property`; `trash`/`restore`/`duplicate`; `db relation link/unlink` — ответная сторона и сводка пересчитаны
- [ ] T046 [P] [US3] `PK/Tests/ControlCommandsTests/Databases/ViewCommandsTests.swift`: `db view add/rename/duplicate/delete/move/list`; `update` с фильтром И/ИЛИ и вложенной группой по именам, сортировками, группировкой, видимостью, порядком, шириной, переносом, итогом, способом открытия, пределом, группами (скрыть, свернуть, порядок), ручным порядком строк; оператор не к типу → `invalid_value` со списком; `db rows --view` — тот же порядок и группы, что `ViewQuery` вида; `--filter/--sort/--search` без сохранения в вид; `--limit/--cursor` на 10 000 строк

### Код

- [ ] T047 [US3] `PK/Sources/ControlCommands/Handlers/DatabaseHandlers/SchemaHandlers.swift` — через `DatabaseOperations` сессии; смена типа на большой базе — `startChangeType` с ожиданием итога до ответа (T044)
- [ ] T048 [US3] `PK/Sources/ControlCommands/Handlers/DatabaseHandlers/RowHandlers.swift` — `addRow`, `writeCells`, `pickOption`, `linkRow/unlinkRow`, пачка в одной сессии с откатом (T045)
- [ ] T049 [US3] `PK/Sources/ControlCommands/Handlers/DatabaseHandlers/ViewHandlers.swift` и `RowsQueryHandler.swift` — `ViewQuery.open/rows`, `RowWindowReader`, курсор по позиции в выдаче (T046)
- [ ] T050 [US3] `db template …`: если шаблоны строк 004 (US6, `PK/Sources/Databases/RowTemplates/`) уже есть в основе — `PK/Sources/ControlCommands/Handlers/DatabaseHandlers/TemplateHandlers.swift` с тестом `TemplateCommandsTests.swift` (создать, по умолчанию, строка по шаблону, удалить); если нет — оставить `not_implemented` и отметить в отчёте фазы
- [ ] T051 [US3] `Tools/mynotion-skill/references/databases.md`: завести базу задач, добавить строки пачкой, настроить вид, прочитать строки вида; значения по типам и операторы фильтра — таблицей; примеры выполнены на iMac
- [ ] T052 [US3] Затронутые тесты зелёные (`ControlCommandsTests/Databases`, `DatabasesTests`); живая проверка шага 7 сценария A — порядок и группы `db rows` совпадают с окном (снимок); замер `db rows` первой страницы на «Задачах» 10 000 ≤ 150 мс; замер запуска и памяти в покое против прошлого этапа (quickstart, «Замеры», конституция II); коммит

---

## Phase 6: User Story 4 — Поиск, избранное, недавние, шаблоны, история, вложения (Priority: P4) — этап 5, волна B (после вливания US1)

**Goal**: найти, отметить, вернуть, приложить

**Independent Test**: spec US4 «Independent Test»; шаги 9–10 сценария A

### Тесты (до кода)

- [ ] T053 [P] [US4] `PK/Tests/ControlCommandsTests/LibraryCommandsTests.swift`: `search` — та же выдача и порядок, что `PageSearch.results` (путь, отрывок, строки баз); `favorites add/remove/move/list`; `recents` как `recentPages`; `template mark/unmark/list`
- [ ] T054 [P] [US4] `PK/Tests/ControlCommandsTests/HistoryCommandsTests.swift`: `history list` с полем `agent`; `show` Markdown и JSON; `restore` — страница как в версии, перед этим снята версия «до восстановления»; `restore` в пакете → `not_batchable`
- [ ] T055 [P] [US4] `PK/Tests/ControlCommandsTests/AttachmentCommandsTests.swift`: `attachment add` PDF → блок-файл, PNG → картинка, MP4 → видео, `--as`; в ячейку «Файлы»; нет файла → `file_not_found`; `list`; `get --to` — байты совпадают

### Код

- [ ] T056 [US4] `PK/Sources/ControlCommands/Handlers/LibraryHandlers.swift`: `PageSearch`, избранное и шаблоны через `PageTreeOperations`, `recentPages`, `PageVersionStore` и `VersionRestorer`, `PageMarkdownReader` для `history show`, `AttachmentStore.importFile/fileURL`, `DatabaseOperations.addFiles` (T053–T055)
- [ ] T057 [US4] `Tools/mynotion-skill/references/library.md`: найти по слову, избранное, создать из шаблона, вернуть версию «до правки агента», приложить файл; примеры выполнены на iMac
- [ ] T058 [US4] Затронутые тесты зелёные; живая проверка шагов 9–10 сценария A; замер запуска и памяти в покое против прошлого этапа (quickstart, «Замеры», конституция II); коммит

---

## Phase 7: User Story 5 — Окно (Priority: P5) — этап 6, волна B

**Goal**: показать Юрию результат: открыть, вкладки, назад и вперёд

**Independent Test**: spec US5 «Independent Test»; шаг 4 сценария A

### Тесты (до кода)

- [ ] T059 [P] [US5] `PK/Tests/ControlCommandsTests/WindowCommandsTests.swift` (подставной `WindowControl`): `window state`; `open` в текущей, новой вкладке, новом окне, с `--block`, с `--activate` и без; окон нет → новое окно; `tab new/select/close/reopen`; `nav back/forward`; лист открыт → `window_busy`; нет вкладки → `tab_not_found`; команды окна в пакете → `not_batchable`

### Код

- [ ] T060 [US5] `PK/Sources/ControlCommands/Handlers/WindowHandlers.swift` (T059)
- [ ] T061 [US5] `App/Control/AppWindowControl.swift`: `MainWindowModel.open(PageOpenRequest)`, `openInNewTab`, `goBack`, `goForward`, `WindowTabs.close/reopenClosedTab`, новое окно через `openWindow(id: MainWindowView.sceneId)`; без `--activate` — `orderFront` без активации, с ним — `NSApp.activate`
- [ ] T062 [US5] `Tools/mynotion-skill/references/window.md`; живая проверка шага 4 сценария A на iMac (снимок; `lsappinfo front` — терминал, без `--activate`); затронутые тесты зелёные; замер запуска и памяти в покое против прошлого этапа (quickstart, «Замеры», конституция II); коммит

---

## Phase 8: User Story 6 — Импорт, выгрузка, синхронизация (Priority: P6) — этап 7, волна B

**Goal**: импорт Notion, выгрузка страницы, ветки, всего, базы; состояние и запуск синхронизации

**Independent Test**: spec US6 «Independent Test»; шаг 12 сценария A

### Тесты (до кода)

- [ ] T063 [P] [US6] `PK/Tests/ControlCommandsTests/TransferCommandsTests.swift`: `import notion` на фикстуре `NotionImportTests/Fixtures` — тот же результат и отчёт, что `NotionImporter.importExport`; ход строками `progress`; чтение во время импорта не ждёт; разрыв клиента — импорт доходит до конца; `export page` (с детьми и `--no-children`), `export all`, `db export` — те же файлы, что `MarkdownExporter`; `sync status` и `sync now` с подставной синхронизацией; выключенная синхронизация — `sync now` → понятная ошибка

### Код

- [ ] T064 [US6] `PK/Sources/ControlCommands/Handlers/TransferHandlers.swift` и `App/Control/AppTransferControl.swift` (контроллеры импорта и выгрузки приложения, `SyncController`) (T063)
- [ ] T065 [US6] `Tools/mynotion-skill/references/transfer.md`; живая проверка шага 12 сценария A и импорта фикстуры на iMac; затронутые тесты зелёные; замер запуска и памяти в покое против прошлого этапа (quickstart, «Замеры», конституция II); коммит

---

## Phase 9: Polish & Cross-Cutting — этап 8 «Итог»

- [ ] T066 `PK/Tests/ControlCommandsTests/CoverageTableTests.swift` (SC-408): каждый публичный метод `PageTreeOperations`, `DatabaseOperations`, `WindowTabs` назван в `contracts/coverage.md` или в его списке «не входит»; каждая команда каталога имеет обработчик (нет `not_implemented`, кроме `db template …` при отсутствии 004 US6 — с причиной)
- [ ] T067 `scripts/imac/cli-e2e.zsh`: сквозной сценарий A (quickstart.md) целиком на Release-сборке, временная база и сокет, `jq -e` на каждом шаге, снимки CuaDriver в `~/work/shots/005/`
- [ ] T068 Главный агент зовёт ревьюера кода (весь дифф 005 против 004-основы): безопасность сокета (права, uid, длина запроса), путь записи (нет SQL мимо операций), откат пакета, утечки сессий; находки — исполнителю; после правок — затронутые тесты
- [ ] T069 Полный прогон один раз на iMac: `swift test --jobs 4` всех модулей, UI-тесты `scripts/imac/run-on-imac.sh uitest`, сценарий A (T067); красные — чинить и повторить затронутые
- [ ] T070 Замеры (quickstart.md, «Замеры»), Release на iMac: ответ p95 (SC-402), запуск командой (SC-402), запуск и память в покое против 004 (SC-406), 0 % процессора в покое; итоги в `quickstart.md`
- [ ] T071 Проверка скилла (SC-401): новый агент Sonnet без знания MyNotion, только скилл и `mynotion` на iMac (временная база), 10 задач из сценариев US1–US3; ≥ 9 без ошибок вызова с первой попытки; правки скилла по провалам
- [ ] T072 README: раздел «Команда mynotion для агентов» (установка, сокет, журнал, модули `Control*`, `PageMarkdown`); установка `scripts/install-cli.sh --target ~/Applications` на iMac и `skill-doctor.sh` для `Tools/mynotion-skill`
- [ ] T073 Итог для Юрия: что сделано, цифры замеров, допущения Q1–Q10 (подтвердить или поменять), статус `db template`. Установку на основной Mac (`scripts/install-cli.sh` — замена `/Applications/MyNotion.app`, ссылка, скилл в `~/.agents/skills/mynotion`) главный агент делает только после «да» Юрия

---

## Dependencies & Execution Order

### Phase Dependencies

- Phase 1–2 (этап 1) — первыми, одним агентом. Всё остальное ждёт их вливания.
- US1, US2, US3 (этапы 2, 3, 4) — после этапа 1, параллельно (волна A).
- US5, US6 (этапы 6, 7) — после этапа 1; стартуют, когда освобождается место (не больше трёх агентов).
- US4 (этап 5) — после вливания US1: `history show` берёт `PageMarkdownReader`.
- Phase 9 — после вливания всех историй.

### Story independence

- Истории не правят общих файлов (plan.md, таблица «Свои файлы»). Каждая проверяется своими тестами и своими шагами сценария A.
- US2 трогает `PageEditor` (перенос правил) — единственная правка существующего модуля интерфейса; US1 трогает `NotionImport` (вынос конвертера). Пересечений нет.

### Within Each Story

- Тесты → код → справочный файл скилла → живая проверка → коммит.

## Parallel Example

```text
# Волна A — три агента, три worktree от ветки с этапом 1:
Этап 2 (US1): T027–T036   worktree MyNotion-005-us1
Этап 3 (US2): T037–T043   worktree MyNotion-005-us2
Этап 4 (US3): T044–T052   worktree MyNotion-005-us3
# Внутри фазы тесты [P] пишутся параллельно: T027, T028, T029, T030, T031.

# Волна B — по мере освобождения мест:
Этап 6 (US5): T059–T062;  Этап 7 (US6): T063–T065;  Этап 5 (US4): T053–T058 после вливания US1
```

## Implementation Strategy

### MVP First

1. Этап 1 (T001–T026) → проверка: команда доходит до приложения, приложение поднимается в фоне.
2. Этап 2 (US1, T027–T036) → MVP: агент читает и пишет страницы. Можно показывать Юрию.

### Incremental Delivery

- Каждая влитая история добавляет группу команд и свой файл скилла. Скилл полезен с первого вливания.
- Вливание по одному, затронутые тесты после каждого. Полный прогон — один раз в Phase 9.
