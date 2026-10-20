---

description: "Задачи: страницы и навигация"
---

# Tasks: Страницы и навигация

**Input**: Design documents from `/specs/003-pages-navigation/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Обязательны — конституция, принцип VI (TDD): в каждой фазе тесты пишутся первыми и должны упасть по нужной причине, затем код, затем зелёные все затронутые.

**Organization**: Фазы идут волнами A–E из plan.md. Каждая история — законченный срез: модель, операция с отменой, синхронизация, вид, выгрузка где нужно, галерея, замер.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно параллельно внутри фазы (другие файлы, нет зависимости от незавершённых задач)
- **[Story]**: история из spec.md (US1…US7)

## Path Conventions

- `PK` = `Packages/MyNotionKit`; модули — `PK/Sources/<Модуль>/`, тесты модулей — `PK/Tests/<Модуль>Tests/`
- Сценарии — `UITests/`, замеры и пробы — `PerformanceTests/`, приложение — `App/`
- Всё живое (UI-тесты, замеры, галерея, пробы) — только в виртуальном Mac: `scripts/vm/run-in-vm.sh uitest|gallery|run`. На основном Mac — только сборка и `swift test`. Каждый worktree — со своими `MYNOTION_VM_DD` и `MYNOTION_UITEST_DD`
- Сверка с Notion — только подстраница «MyNotion — блоки 002» или её новая подстраница, один замок `scripts/vm/run-in-vm.sh lock -- …`, без ⌘Z в Notion (research R14)

---

## Phase 1: Setup — волна A, агент «Фундамент»

**Purpose**: новые модули и места «файл на пункт», чтобы параллельные этапы добавляли файлы, а не правили общие

- [x] T001 В `PK/Package.swift` добавить цели и тестовые цели: `Backlinks` (NotesCore, GRDB), `PageVersions` (NotesCore, GRDB), `Navigation` (NotesCore), `PagePicker` (NotesCore, PageSearch, VisualStyle), `PageCover` (NotesCore, Attachments, VisualStyle); создать папки `PK/Sources/NotesCore/Copying/`, `PK/Sources/PageEditor/{PageHeader,PageLayout,VersionPreview,TemplateRows}/`, `PK/Sources/PageTree/{SidebarSections,PageRowMenu}/`, `App/MainWindow/PageMenu/`
- [x] T002 В `project.yml` подключить новые модули к приложению `MyNotion`; проверить `xcodegen generate && xcodebuild build -scheme MyNotion` на основном Mac

---

## Phase 2: Foundational (этап 0) — волна A, агент «Фундамент»

**Purpose**: пробы рисков, модель v7, формат v3, общая копия блоков и веток, реестры. ⚠️ Ни одна история не начинается до конца фазы.

### Пробы рисков (первыми, research R14; каждая — цифра и снимок отрисовки)

- [x] T003 Проба вида страницы в `PerformanceTests/Probes/PageLayoutProbeTests.swift` + черновой `PK/Sources/PageEditor/PageLayout/PageLayoutSettings.swift`: «богатая» страница 002 с заглушкой обложки высотой 280 над шапкой; «мелкий шрифт» и «широкая» туда и обратно — перекладка ≤ 200 мс; после каждого шага снимок окна: ширина строки и размер шрифта изменились, таблица, код и картинка 002 нарисованы не пустыми (доля непустых пикселей в их рамках); набор после переключения p95 ≤ 50 мс; прогон `scripts/vm/run-in-vm.sh uitest --release -only-testing:PerformanceTests/PageLayoutProbeTests`
- [x] T004 [P] Проба вкладок в `PerformanceTests/Probes/TabsProbeTests.swift`: 20 «вкладок» — переходы по кругу между 20 «богатыми» страницами через заглушку модели вкладок; p95 ≤ 50 мс; после 100 переключений живой один `PageTextView` (счётчик экземпляров в отладочной сборке); прирост памяти ≤ 5 МБ; место прокрутки вернулось (тот же блок у верха на снимке)
- [x] T005 [P] Проба просмотра версии в `PerformanceTests/Probes/VersionPreviewProbeTests.swift`: второй редактор «только чтение» на документе из 1 000 блоков поверх окна — показ ≤ 500 мс; снимок не пустой, виды 002 нарисованы; нажатия клавиш документ не меняют; после закрытия память — исходная ± 5 МБ
- [x] T006 [P] Проба копии ветки в `PerformanceTests/Probes/BranchCopyProbeTests.swift`: 50 подстраниц, 5 000 блоков, 10 картинок — копия одной транзакцией ≤ 2 с; главный поток не замирает дольше 100 мс (таймер на главном потоке каждые 16 мс); копия читается с тем же текстом
- [x] T007 Записать итоги T003–T006 в `specs/003-pages-navigation/research.md` (R15, с датой, цифрами и путями снимков) и `quickstart.md`; при провале пункта зафиксировать запасной путь (R14) до начала зависящей истории; коммит «Этап 0: пробы»

### Тесты фундамента (до кода, должны быть красными)

- [x] T008 [P] Тест миграции v7 в `PK/Tests/NotesCoreTests/DatabaseMigrationTests.swift`: эталон v6 → v7 — страницы, блоки, вложения, напоминания, очередь исходящих на месте; новые колонки страницы со значениями по умолчанию, `fieldClocks` с новыми ключами пустыми; таблицы `page_link` (пустая), `page_version`, `page_version_due`, `app_meta`; `window_state.tabs`, `collapsedSidebarSections`; копия `MyNotion.backup-v6.sqlite` и восстановление из неё; повтор ничего не меняет; база новее приложения — «База от новой версии MyNotion», запись не идёт
- [x] T009 [P] Тест модели в `PK/Tests/NotesCoreTests/PageModelTests.swift`: `PageCover` (галерея, файл, `offset` урезается к 0…1, неизвестный id сохраняется); `changedFields` различает шесть новых полей; `favorite` и `visitedAt` не меняют `updatedAt`; `DateMention.templateRelative` кодируется и неизвестные ключи даты сохраняются; `Tab` и `WindowState.tabs` кодируются по data-model.md
- [x] T010 [P] Тест формата v3 в `PK/Tests/SyncTests/SyncPayloadV3Tests.swift`: кодирование и разбор всех значений contracts/sync-v3-and-export.md (примеры дословно); `formatVersion` 3; пачка v2 читается; Mac с форматом 2 пачку v3 не применяет и показывает «Обновите MyNotion на этом Mac»
- [x] T011 [P] Тест слияния в `PK/Tests/SyncTests/ChangeMergerV3Tests.swift`: «позднее побеждает» для каждого нового поля; одновременная перестановка избранного на двух клиентах сходится к одному порядку без потерь строк; `visitedAt` с двух Mac — позднее; обложка-файл без файла ставит его в очередь докачки 002; снимок v3 переносит новые поля
- [x] T012 [P] Тест копии блоков в `PK/Tests/NotesCoreTests/BlockCopierTests.swift`: блоки с поддеревом, колонками и таблицей — новые id, `columnId` ячеек на копии столбцов, глубина относительно первого, `props` и цвет те же, `movedFrom` ставится по запросу; все тесты «Преобразовать в → Страница» 001–002 (`PageTreeOperationsTests`) зелёные после перевода на копировщик
- [x] T013 [P] Тест копии ветки в `PK/Tests/NotesCoreTests/PageBranchCopierTests.swift` строго по contracts/page-operations.md, «Дублирование»: страницы ветки вне корзины, все потоки, иконка, обложка, вид; `pageLink` внутри ветки → копии, вне — как было; упоминания как были; напоминания выключены; `AttachmentRef` та же и счётчик ссылок 002 считает копию; даты с `templateRelative` → момент создания (часы подменены)
- [x] T014 [P] Тест запросов в `PK/Tests/NotesCoreTests/FavoritesRecentsQueryTests.swift`: избранное по ключу без корзины; недавние по `visitedAt` без корзины и шаблонов, лимит 5 и 50; запросы идут по индексам (`EXPLAIN QUERY PLAN`)
- [x] T015 [P] Тест реестров в `PK/Tests/PageEditorTests/PageMenusRegistryTests.swift` и `PK/Tests/PageTreeTests/SidebarRegistryTests.swift`: меню «•••», меню строки панели и разделы панели собираются из описателей в порядке contracts/pages-ui.md; шапка страницы раскладывает места «обложка», «кнопки», «название», «под названием» — пустые места не занимают высоты; вид шапки 001 без обложки не изменился (сравнение рамок с 002)

### Код фундамента

- [x] T016 Модель в `PK/Sources/NotesCore/Model/Page.swift`, новый `PageCover.swift`, `DateMention.swift`, `WindowState.swift` (`Tab`, `tabs`, `collapsedSidebarSections`) строго по data-model.md (T009)
- [x] T017 Миграция v7 в `PK/Sources/NotesCore/Storage/SchemaMigrations.swift`, чтение и запись в `RowMapping.swift`, `NotesTransaction.swift`, `NotesStore.swift` (окно), таблица `app_meta` (T008)
- [x] T018 Синхронизация v3: `PK/Sources/Sync/SyncPayload.swift`, `Outbox.swift`, `ChangeMerger.swift`, `SyncSnapshot.swift`; обложка-файл — в очередь докачки `PK/Sources/Attachments/AttachmentTransfer.swift` (T010, T011)
- [x] T019 Копирование в `PK/Sources/NotesCore/Copying/BlockCopier.swift` и `PageBranchCopier.swift`; `PageTreeOperations.moveChildren` переведён на `BlockCopier`; `perform` и `registerUndo` в `PageTreeOperations.swift` — `internal`, чтобы истории писали операции в своих файлах-расширениях `PK/Sources/NotesCore/Tree/PageTreeOperations+<Тема>.swift` (T012, T013)
- [x] T020 Запросы избранного и недавних в `PK/Sources/NotesCore/Storage/NotesStore+FavoritesRecents.swift` (T014)
- [x] T021 Модуль `Navigation`: `PK/Sources/Navigation/WindowTabs.swift` (вкладки, активная, открыть в активной/новой, хранение в `window_state.tabs`), `PageOpenRequest.swift` (`pageId`, `inNewTab`, `revealBlockId`); `App/MainWindow/MainWindowModel.swift` открывает страницы через `WindowTabs` (одна вкладка — поведение 002 без изменений); событие «страница открыта / ушли со страницы» для записи недавних (US2); `onOpenPage` редактора, строк панели и поиска передаёт `PageOpenRequest` с ⌘ (US3 включает новую вкладку)
- [x] T022 Реестры: `PK/Sources/PageTree/PageRowMenu/PageRowMenuItem.swift` (меню строки собирается из описателей; пункты 001 — по файлу), `PK/Sources/PageTree/SidebarSections/SidebarSection.swift` (раздел «Страницы» — описатель), `App/MainWindow/PageMenu/PageMenuItem.swift` и верхняя полоса справа: «•••» с меню из описателей (пункты этапа 0: «Найти действие…», «Удалить в корзину», подвал «Изменено …, N слов»), место под «☆» (US2); шапка в `PK/Sources/PageEditor/PageHeader/` — места «обложка», «кнопки», «название», «под названием» (T015)
- [x] T023 [P] Дополнения 003 в `PK/Sources/NotesCore/Fixtures/ReferenceLibraryGenerator.swift` и `RichPageGenerator.swift` (состав — quickstart.md; каждая история дописывает свою часть), флаг `--generate-003-sample` в `App/MyNotionApp.swift`; состояния галереи «меню •••», «верхняя полоса» в `PK/Sources/UIGallery/GalleryCatalog.swift`
- [x] T024 Затронутые тесты зелёные (`swift test`); замер запуска, памяти и перехода в виртуальном Mac (`scripts/vm/run-in-vm.sh uitest --release -only-testing:PerformanceTests/LaunchAndMemoryTests -only-testing:PerformanceTests/TypingAndNavigationTests`) не хуже 002 (0,36–0,38 с, 46 МБ, переход p95 ≤ 50 мс); миграция эталона v7 ≤ 2 с; запись в quickstart.md, раздел «Этап 0»; коммит

**Checkpoint**: фундамент готов — волна B стартует.

---

## Phase 3: User Story 1 — Обложка, широкая страница и мелкий шрифт (Priority: P1) 🎯 MVP — волна B, агент «Шапка»

**Goal**: обложка из галереи и своя, сдвиг, стык с иконкой; «Вид страницы».

**Independent Test**: spec, US1: обложка из галереи → своя → сдвиг → убрать; широкая и мелкий шрифт; перезапуск; выгрузка.

### Tests for User Story 1

- [x] T025 [P] [US1] `PK/Tests/PageCoverTests/PageCoverOperationsTests.swift`: поставить из галереи, случайная — из списка contracts/pages-ui.md, своя картинка (не картинка и > 100 МБ — ошибка, обложка прежняя), сдвиг, убрать; каждая — одна правка с ⌘Z; файл обложки не стирается, пока на него ссылаются
- [x] T026 [P] [US1] `PK/Tests/PageEditorTests/PageLayoutSettingsTests.swift`: ширина колонки обычной и широкой страницы при ширинах окна 900, 1200, 1800; шкала 14/16 для абзаца, заголовков, кода, таблицы; название не меняется
- [x] T027 [P] [US1] `PK/Tests/MarkdownExportTests/CoverExportTests.swift` + `PK/Tests/NotionImportTests/CoverImportTests.swift`: комментарий и файл `Обложка.*` дословно по contracts/sync-v3-and-export.md; обратный импорт ставит обложку (SHA-256 тот же); отчёт импорта Notion называет потерю обложек
- [x] T028 [P] [US1] XCUITest `UITests/PageHeaderTests.swift`: наведение на шапку — «Добавить обложку»; щелчок — обложка; «Сменить обложку» → «Загрузить» картинку из тестовой папки; «Переместить» → «Сохранить положение»; «Убрать»; «•••» → «Вид страницы» → оба переключателя; перезапуск — всё на месте; ⌘Z

### Implementation for User Story 1

- [x] T029 [US1] Галерея в `PK/Sources/PageCover/CoverGallery.swift`: id и цвета, снятые с `notion.so/images/page-cover/<id>.png` (картинки — только для сверки, в сборку не кладутся), рисование заливки и градиента; сверка состава с окном «Change cover» живого Notion (одним замком)
- [x] T030 [US1] Вид обложки в `PK/Sources/PageCover/CoverView.swift` в месте «обложка» шапки: высота, заполнение по ширине, `offset`, уменьшенная копия через ImageIO, заглушка не пришедшего файла; иконка заходит на обложку; цифры шапки — со снимка `notion-cover.png` и живого Notion, правка ≈ в contracts/pages-ui.md
- [x] T031 [US1] Кнопки при наведении («Добавить обложку» в месте «кнопки»; «Сменить обложку», «Переместить» на обложке), окно «Сменить обложку» (`PK/Sources/PageCover/CoverPickerView.swift`: «Галерея», «Загрузить» с выбором файла и перетаскиванием, «Убрать»), режим «Переместить» (`CoverRepositionMode.swift`)
- [x] T032 [US1] Операции в `PK/Sources/NotesCore/Tree/PageTreeOperations+Appearance.swift`: обложка, сдвиг, вид страницы — с отменой; своя картинка — через хранилище вложений 002 (T025)
- [x] T033 [US1] «Вид страницы» в `PK/Sources/PageEditor/PageLayout/` (ширина и шкала шрифтов для текста и видов 002, перекладка без пересоздания редактора) и пункт `App/MainWindow/PageMenu/PageAppearanceMenuItem.swift` с переключателями (T026)
- [x] T034 [US1] Выгрузка обложки в `PK/Sources/MarkdownExport/` и чтение в `PK/Sources/NotionImport/` (T027)
- [x] T035 [US1] Состояния галереи: шапка без обложки при наведении, обложка галереи и картинки, при наведении, «Переместить», окно «Сменить обложку» (обе вкладки), мелкий шрифт, широкая — в обеих темах; сверка с `visual-reference/` и живым Notion
- [x] T036 [US1] Затронутые тесты зелёные; замеры: набор на «богатой» странице с обложкой, мелким шрифтом и широкой ≤ 50 мс p95, переключение ≤ 200 мс, переход и запуск — со снимками; запись в quickstart.md; коммит

**Checkpoint**: US1 работает и проверяется сама.

---

## Phase 4: User Story 2 — Избранное и недавние (Priority: P2) — волна B, агент «Панель»

**Goal**: разделы «Недавние» и «Избранное», ☆ в верхней полосе, запись открытий.

**Independent Test**: spec, US2.

### Tests for User Story 2

- [x] T037 [P] [US2] `PK/Tests/NotesCoreTests/FavoriteOperationsTests.swift` по contracts/page-operations.md, «Избранное»: добавить в конец, убрать, переставить (меняется ключ только у перетащенной), корзина прячет и возвращает, удаление навсегда; ⌘Z каждого
- [x] T038 [P] [US2] `PK/Tests/NavigationTests/VisitRecorderTests.swift` с подменёнными часами: 2 с на странице — запись; уход за 1,9 с — нет; правка раньше 2 с — запись; повторное открытие той же — одна запись; `updatedAt` не меняется
- [x] T039 [P] [US2] XCUITest `UITests/FavoritesRecentsTests.swift`: ☆ у двух страниц и «Добавить в избранное» в меню панели у третьей; перетаскивание в разделе; ☆ ещё раз — убрана; открыть 6 страниц по 3 с — 5 в «Недавних» по порядку; страница в корзину — пропала из обоих разделов, вернуть — снова в избранном; щелчок по заголовку раздела сворачивает; перезапуск — всё на месте

### Implementation for User Story 2

- [x] T040 [US2] Операции в `PK/Sources/NotesCore/Tree/PageTreeOperations+Favorites.swift` (T037)
- [x] T041 [US2] Запись открытий `PK/Sources/Navigation/VisitRecorder.swift` по событию «страница открыта / ушли» из T021; правка в странице — сразу (T038)
- [x] T042 [US2] Разделы `PK/Sources/PageTree/SidebarSections/RecentSection.swift` (5 строк и «Показать все» — действие панели `showAllRecent`, его открывает US3) и `FavoritesSection.swift` (строки дерева с раскрытием подстраниц, перетаскивание); свёртывание разделов с хранением в `window_state.collapsedSidebarSections`
- [x] T043 [US2] ☆ в верхней полосе (`App/MainWindow/PageMenu/FavoriteStarButton.swift`) и пункт `PK/Sources/PageTree/PageRowMenu/FavoriteRowMenuItem.swift`
- [x] T044 [US2] Состояния галереи: панель с «Недавними» и «Избранным», свёрнутый раздел, ☆ закрашенная и пустая, меню строки — в обеих темах; сверка с `notion-sidebar-tabs-topbar.png`
- [x] T045 [US2] Затронутые тесты зелёные; замеры перехода (запись открытия вне пути перехода) и запуска; запись в quickstart.md; коммит

**Checkpoint**: US2 работает и проверяется сама.

---

## Phase 5: User Story 3 — Вкладки и «назад/вперёд» (Priority: P3) — волна B, агент «Вкладки»

**Goal**: вкладки окна как у Notion для Mac, история «назад/вперёд» у каждой вкладки.

**Independent Test**: spec, US3.

### Tests for User Story 3

- [x] T046 [P] [US3] `PK/Tests/NavigationTests/NavigationHistoryTests.swift` по contracts/page-operations.md, «Вкладки и история»: стопки, очистка «вперёд», повтор той же страницы, лимит 50, пропуск удалённых навсегда, заглушка корзины, место прокрутки в записи
- [x] T047 [P] [US3] `PK/Tests/NavigationTests/WindowTabsTests.swift`: новая вкладка справа от текущей (⌘-щелчок не меняет активную), закрытие, ⇧⌘T на прежнее место со своей историей, стопка 20 закрытых, перестановка, ⌘W последней — закрыть окно, хранение и чтение `window_state.tabs`
- [x] T048 [P] [US3] XCUITest `UITests/TabsNavigationTests.swift`: три перехода по упоминаниям, ⌘[ ×2 — место прокрутки то же, ⌘] ×1; «‹ ›» серые на краях; ⌘T → «Недавние» с поиском → открыть; ⌘-щелчок в панели — новая вкладка, активная прежняя; ⌃⇥, ⌃⇧⇥; перетаскивание вкладки; ⌘W, ⇧⌘T; «Показать все» в панели — вкладка «Недавние»; перезапуск — вкладки и активная на месте

### Implementation for User Story 3

- [x] T049 [US3] История в `PK/Sources/Navigation/NavigationHistory.swift`; место прокрутки — id блока у верха и сдвиг, возврат через `blockReveal` 002 (T046)
- [x] T050 [US3] `WindowTabs` — закрытие, ⇧⌘T, перестановка, хранение; при запуске открывается только активная вкладка (T047)
- [x] T051 [US3] Полоса вкладок `App/MainWindow/TabStrip/TabStripView.swift` в строке светофора (с панелью и без), «‹ ›», «+», «×», перетаскивание; цифры — со снимка `notion-sidebar-tabs-topbar.png`, правка ≈ в contracts/pages-ui.md
- [x] T052 [US3] Меню Mac в `App/Commands/NavigationCommands.swift`: «Файл» (Новая вкладка ⌘T, Открыть закрытую вкладку ⇧⌘T, Закрыть вкладку ⌘W), «История» (Назад ⌘[, Вперёд ⌘]) между «Вид» и «Окно», «Окно» (Предыдущая ⌃⇧⇥, Следующая ⌃⇥)
- [x] T053 [US3] ⌘-щелчок: `PageOpenRequest.inNewTab` из строк панели, упоминаний и подстраниц (`PageTextView`), выдачи поиска, недавних
- [x] T054 [US3] Вкладка «Недавние» / «Новая вкладка» `App/MainWindow/RecentPagesView.swift` (поиск 001 и до 50 недавних по contracts/pages-ui.md); действие панели `showAllRecent`; заглушка «Страница в корзине» с «Вернуть»
- [x] T055 [US3] Состояния галереи: 1, 3 и 12 вкладок, активная, наведение с «×», панель спрятана, «Новая вкладка», заглушка корзины — в обеих темах; сверка с Notion
- [ ] T056 [US3] Затронутые тесты зелёные; замеры: переключение вкладки, «назад», «вперёд» p95 ≤ 50 мс; 20 вкладок ≤ +5 МБ; запуск с 10 вкладками ≤ 1 с — со снимками; запись в quickstart.md; коммит

**Checkpoint**: волна B готова. Вливание в `003-pages-navigation` по одному: US1, US2, затем US3 (правит те же места `MainWindowView.swift` и `MainWindowModel.swift`); после каждого — затронутые тесты.

---

## Phase 6: User Story 4 — Дублирование страницы и перенос блоков (Priority: P4) — волна C, агент «Копии»

**Goal**: «Дублировать», «Переместить в» для блоков и страниц, окно выбора страницы.

**Independent Test**: spec, US4.

### Tests for User Story 4

- [x] T057 [P] [US4] `PK/Tests/NotesCoreTests/DuplicatePageTests.swift` по contracts/page-operations.md, «Дублирование»: название «(1)» и следующий свободный, место под оригиналом и ссылка в родителе следом, копия шаблона — шаблон, ⌘Z удаляет копию одной правкой
- [x] T058 [P] [US4] `PK/Tests/NotesCoreTests/MoveBlocksToPageTests.swift` по contracts/page-operations.md, «Перенос блоков»: конец потока цели, глубины, контейнеры, `movedFrom`, подстраницы переезжают, ⌘Z возвращает исходные с прежними id и прежнего родителя подстраниц; цель — та же страница недоступна
- [x] T059 [P] [US4] `PK/Tests/PagePickerTests/PagePickerModelTests.swift`: без запроса — 5 недавних и дерево; с запросом — выдача поиска; недоступные (сама страница и потомки для страницы, исходная для блоков, корзина); клавиатура ↑↓ → Enter Esc
- [x] T060 [P] [US4] XCUITest `UITests/DuplicateMoveTests.swift`: «•••» → «Дублировать» у страницы с двумя подстраницами, картинкой и файлом — открыта «(1)», подстраницы-копии, файл открывается; ⌘D при фокусе в панели; выделить три блока с вложенными → ⇧⌘P → поиск → Enter — блоки в конце другой страницы; ⌘Z; «Переместить в» страницы из меню панели

### Implementation for User Story 4

- [x] T061 [US4] Дублирование в `PK/Sources/NotesCore/Tree/PageTreeOperations+Duplicate.swift` на `PageBranchCopier` (T057); открыть копию — `App/MainWindow/MainWindowModel.swift`
- [x] T062 [US4] Перенос блоков в `PK/Sources/NotesCore/Tree/PageTreeOperations+MoveBlocks.swift` на `BlockCopier` с `movedFrom` (T058); перенос страницы — существующий `move` в конец детей цели
- [x] T063 [US4] Окно `PK/Sources/PagePicker/PagePickerView.swift` и модель (T059); вид — по `notion-move-to.png`
- [x] T064 [US4] Пункты: «Дублировать», «Переместить в» в `App/MainWindow/PageMenu/` и `PK/Sources/PageTree/PageRowMenu/`; «Переместить в» в меню блока (`PK/Sources/PageEditor/SlashCommandMenu.swift`, `blockMenuItems`); маршрут ⌘D (текст и выделенные блоки — блок, фокус в панели — страница) и ⇧⌘P (выделенные блоки — блоки, иначе страница)
- [x] T065 [US4] Состояния галереи: окно «Переместить в» без запроса и с запросом, недоступная строка, меню блока с пунктом — в обеих темах; сверка с Notion
- [x] T066 [US4] Затронутые тесты зелёные; замер дублирования ветки 50 подстраниц / 5 000 блоков ≤ 2 с, главный поток ≤ 100 мс (SC-204); запись в quickstart.md; коммит

**Checkpoint**: US4 работает и проверяется сама.

---

## Phase 7: User Story 5 — Обратные ссылки (Priority: P5) — волна C, агент «Ссылки»

**Goal**: индекс ссылок, строка под названием, список и переход.

**Independent Test**: spec, US5.

### Tests for User Story 5

- [x] T067 [P] [US5] `PK/Tests/BacklinksTests/PageLinkIndexTests.swift`: подписчик записи по contracts/page-operations.md, «Обратные ссылки» — упоминание, `pageLink` на чужую страницу, `pageLink` родителя на ребёнка не пишется, правка и удаление блока, пачка с другого Mac, импорт; первое заполнение по всем блокам один раз (отметка в `app_meta`)
- [x] T068 [P] [US5] `PK/Tests/BacklinksTests/BacklinksQueryTests.swift`: разные страницы-источники; корзина и шаблоны не считаются; сама страница не считается; склонение «1 обратная ссылка / 3 обратные ссылки / 5 обратных ссылок»
- [x] T069 [P] [US5] XCUITest `UITests/BacklinksTests.swift`: на Б ссылаются А (упоминание), В (упоминание) и Г (ссылка на страницу) — «↗ 3 обратные ссылки»; список, переход к блоку ссылки на А; стереть упоминание на В — 2; Г в корзину — 1

### Implementation for User Story 5

- [x] T070 [US5] Подписчик `PK/Sources/Backlinks/PageLinkIndexer.swift` и первое заполнение в фоне после готовности редактора `BacklinkIndexBuild.swift` (T067)
- [x] T071 [US5] Запросы `PK/Sources/Backlinks/Backlinks.swift` (T068)
- [x] T072 [US5] Строка «↗ N обратных ссылок» в месте «под названием» (`PK/Sources/PageEditor/PageHeader/BacklinksRow.swift`), всплывающий список, переход к блоку через `PageOpenRequest.revealBlockId`; счёт читается при открытии одним запросом
- [x] T073 [US5] Состояния галереи: строка и список в обеих темах; сверка с Notion на подстранице «MyNotion — блоки 002», где есть упоминание (одним замком, правки в Notion — убрать восстановлением версии)
- [x] T074 [US5] Затронутые тесты зелёные; замеры: переход между страницами со счётом ссылок p95 ≤ 50 мс (SC-206), первое заполнение эталона ≤ 5 с без замирания окна; запись в quickstart.md; коммит

**Checkpoint**: US5 работает и проверяется сама.

---

## Phase 8: User Story 6 — История версий (Priority: P6) — волна C, агент «Версии»

**Goal**: запись версий, просмотр, восстановление.

**Independent Test**: spec, US6.

### Tests for User Story 6

- [x] T075 [P] [US6] `PK/Tests/PageVersionsTests/PageSnapshotTests.swift`: снимок всех потоков и полей страницы, сжатие и разбор, `snapshotVersion`; снимок 1 000 блоков — размер записать
- [x] T076 [P] [US6] `PK/Tests/PageVersionsTests/PageVersionRecorderTests.swift` с подменёнными часами по contracts/page-operations.md, «История версий»: отметка от своей правки и от пачки с другого Mac (автор — тот Mac); не чаще раза в минуту; 5 с тишины; `favorite` и `visitedAt` не отмечают; первое открытие без версий — снимок «как было»; закрытие окна — снимки всех отмеченных; ни одного снимка до готовности редактора
- [x] T077 [P] [US6] `PK/Tests/PageVersionsTests/VersionPruningTests.swift`: правило Clarifications дословно; последняя версия остаётся всегда; удаление страницы навсегда стирает её версии
- [x] T078 [P] [US6] `PK/Tests/PageVersionsTests/VersionDiffTests.swift`: `summary` (название, иконка, обложка, вид, блоки добавлены/удалены/изменены); id блоков для подсветки
- [x] T079 [P] [US6] `PK/Tests/PageVersionsTests/VersionRestoreTests.swift`: поля и блоки как в версии; удалённые с тех пор — возвращены с прежними id; копии с `movedFrom` на других страницах — удалены; снимок «до восстановления» и новая версия после; ⌘Z — как было; изменения уходят в исходящие синхронизации
- [x] T080 [P] [US6] XCUITest `UITests/VersionHistoryTests.swift`: правки с подменёнными часами (флаг запуска) → «•••» → «История версий»; группировка; раскрытие версии; выбрать раннюю → подсветка → «Восстановить» → «Восстановить эту версию» → полоса «Страница восстановлена»; ⌘Z; Esc закрывает

### Implementation for User Story 6

- [x] T081 [US6] Снимок и хранение `PK/Sources/PageVersions/PageSnapshot.swift`, `PageVersionStore.swift` (T075)
- [x] T082 [US6] Подписчик `PageVersionDueMarker.swift` и записыватель `PageVersionRecorder.swift`: старт после готовности редактора, по событию, вне главного потока; снимок при закрытии окна и выходе; первая версия при открытии (T076)
- [x] T083 [US6] Прореживание `VersionPruning.swift` раз в сутки после готовности редактора; стирание с удалением страницы навсегда (T077)
- [x] T084 [US6] Разница `VersionDiff.swift` (T078) и восстановление `PK/Sources/NotesCore/Tree/PageTreeOperations+RestoreVersion.swift` (T079)
- [x] T085 [US6] Просмотр `PK/Sources/PageEditor/VersionPreview/`: редактор «только чтение» на документе из снимка, подсветка блоков по разнице; по пробе T005
- [x] T086 [US6] Окно истории `App/MainWindow/VersionHistory/` (список, группировка, раскрытие, «Восстановить», окно «Что будет восстановлено», полоса после) по contracts/pages-ui.md и снимкам `notion-version-*.png`; пункт `App/MainWindow/PageMenu/VersionHistoryMenuItem.swift`
- [x] T087 [US6] Состояния галереи: история со списком, группировка, раскрытая версия, окно восстановления, полоса — в обеих темах; сверка со снимками Notion
- [x] T088 [US6] Затронутые тесты зелёные; замеры: история и показ версии ≤ 0,5 с, восстановление ≤ 1 с (SC-205), набор p95 ≤ 50 мс при записи версий (SC-203), место 200 версий «богатой» страницы; запись в quickstart.md; коммит

**Checkpoint**: волна C готова. Вливание по одному: US5, US4, US6 (US4 и US6 правят разные места `MainWindowModel.swift`); после каждого — затронутые тесты.

---

## Phase 9: User Story 7 — Шаблоны страниц (Priority: P7) — волна D, агент «Шаблоны»

**Goal**: шаблоны в своём разделе, заполнение новой страницы из шаблона.

**Independent Test**: spec, US7.

### Tests for User Story 7

- [x] T089 [P] [US7] `PK/Tests/NotesCoreTests/TemplateOperationsTests.swift` по contracts/page-operations.md, «Шаблоны»: сделать (в корень, ссылка у прежнего родителя убрана) и перестать, ⌘Z; шаблон в корзине не предлагается
- [x] T090 [P] [US7] `PK/Tests/NotesCoreTests/TemplateInstantiationTests.swift`: заполнение пустой страницы (поля, блоки, подстраницы-копии), одна правка с ⌘Z; «Новая страница по шаблону» — в корне; `templateRelative` → момент создания (часы подменены); правка шаблона не меняет прежние копии; «@сегодня» в шаблоне ставит `templateRelative`, вне шаблона — нет
- [x] T091 [P] [US7] XCUITest `UITests/TemplatesTests.swift`: «Сделать шаблоном» у страницы с подстраницей и «@сегодня» — раздел «Шаблоны»; ⌘N → строка шаблона → копия с подстраницей, курсор в названии, дата — сегодня; меню шаблона → «Новая страница по шаблону»; «Перестать быть шаблоном»

### Implementation for User Story 7

- [x] T092 [US7] Операции `PK/Sources/NotesCore/Tree/PageTreeOperations+Templates.swift` на `PageBranchCopier` (T089, T090)
- [x] T093 [US7] Раздел `PK/Sources/PageTree/SidebarSections/TemplatesSection.swift`, шаблоны скрыты из «Страниц»; пункты меню «•••» и строки панели (`MakeTemplate*`, `NewFromTemplateRowMenuItem.swift`)
- [x] T094 [US7] Строки шаблонов на пустой странице `PK/Sources/PageEditor/TemplateRows/` (до 5, «Ещё шаблоны…» с поиском, ↑↓ Enter); «@сегодня» / «@сейчас» в шаблоне ставят `templateRelative` (`PK/Sources/PageEditor/Inline/`)
- [x] T095 [US7] Состояния галереи: раздел «Шаблоны», пустая страница со строками шаблонов, «Ещё шаблоны…» — в обеих темах
- [x] T096 [US7] Затронутые тесты зелёные; замер перехода и запуска; запись в quickstart.md; коммит

**Checkpoint**: все истории готовы.

---

## Phase 10: Polish (этап 8) — волна E, агент «Итог»

- [ ] T097 `PK/Tests/NotesCoreTests/NoLossRoundTripTests.swift` (SC-208): «дублировать → удалить копию», «перенести → ⌘Z», «восстановить → ⌘Z», «сделать шаблоном → создать → перестать» — текст и блоки как в начале на эталоне
- [ ] T098 [P] `PK/Tests/NotionImportTests/RichRoundTripTests.swift` дополнить обложками (галерея и файл): выгрузка → импорт без потерь, SHA-256 тот же
- [ ] T099 [P] `PK/Tests/SyncTests/SyncConvergenceTests.swift` (два клиента, поддельный сервер): все новые поля, избранное с двух Mac, восстановление версии, перенос блоков, дублирование, шаблоны сходятся; Mac с форматом 2 — «Обновите MyNotion»
- [ ] T100 Живая проверка двух Mac `scripts/vm/sync-live-check.sh` (свой сервер в виртуальном Mac, не боевой) по пяти шагам quickstart.md; итоги и снимки — в quickstart.md
- [ ] T101 Галерея целиком в обеих темах; главный агент зовёт проверяющего: сверка с `visual-reference/` и живым Notion (одним замком, на подстранице «MyNotion — блоки 002»); находки — исполнителю этой фазы
- [ ] T102 Полный прогон тестов один раз: `swift test` и все UI-тесты в виртуальном Mac; красные — чинить и повторить затронутые
- [ ] T103 Полные замеры (quickstart.md, вся таблица) в виртуальном Mac, Release, со снимками отрисовки; переход между страницами — три прогона, выбросы отделить
- [ ] T104 Сборка Release; переход базы v6 → v7 на копии реальной базы в виртуальном Mac; README: модули 003, вкладки и меню «История»
- [ ] T105 Итог для Юрия: что сделано, цифры замеров, два решения по умолчанию (срок истории версий, вид шаблонов) — подтвердить или поменять

---

## Dependencies & Execution Order

### Волны и агенты (не больше трёх одновременно, каждый в своём git worktree от `003-pages-navigation`)

| Волна | Агент 1 | Агент 2 | Агент 3 | Старт |
|-------|---------|---------|---------|-------|
| **A** | Фундамент: фазы 1–2 (T001–T024) | — | — | сразу |
| **B** | US1 «Шапка»: фаза 3 (T025–T036) | US2 «Панель»: фаза 4 (T037–T045) | US3 «Вкладки»: фаза 5 (T046–T056) | после T024 |
| **C** | US4 «Копии»: фаза 6 (T057–T066) | US5 «Ссылки»: фаза 7 (T067–T074) | US6 «Версии»: фаза 8 (T075–T088) | после вливания B |
| **D** | US7 «Шаблоны»: фаза 9 (T089–T096) | — | — | после вливания C |
| **E** | Polish: фаза 10 (T097–T105) | — | — | после вливания D |

### Почему этапы одной волны независимы (не правят одни файлы)

- **A** один: все общие файлы (`Page.swift`, `SyncPayload.swift`, `ChangeMerger.swift`, `RowMapping.swift`, `SchemaMigrations.swift`, `WindowState.swift`, `PageTreeOperations.swift`, реестры, шапка) правятся здесь.
- **B**: US1 — `PageCover/`, `PageEditor/{PageHeader,PageLayout}/`, `PageTreeOperations+Appearance.swift`, `MarkdownExport`, `NotionImport`, `PageMenu/PageAppearanceMenuItem.swift`; US2 — `PageTreeOperations+Favorites.swift`, `Navigation/VisitRecorder.swift`, `SidebarSections/{Recent,Favorites}Section.swift`, `PageRowMenu/FavoriteRowMenuItem.swift`, `PageMenu/FavoriteStarButton.swift`; US3 — `Navigation/{NavigationHistory,WindowTabs}.swift`, `App/MainWindow/TabStrip/`, `App/Commands/NavigationCommands.swift`, `RecentPagesView.swift`, `PageTextView.swift` (⌘-щелчок). **Пересечения**: `App/MainWindow/MainWindowView.swift` (US2 — разделы панели, US3 — полоса вкладок и вкладка «Недавние») и `App/MainWindow/MainWindowModel.swift` (US2 — подписка записи открытий, US3 — переходы через вкладки). Разные места; конфликт при вливании решает главный агент; US3 вливается последним. `GalleryCatalog.swift` и генератор — каждая история добавляет свои строки в конец списков (конфликты построчные).
- **C**: US4 — `PageTreeOperations+{Duplicate,MoveBlocks}.swift`, `PagePicker/`, `SlashCommandMenu.swift`, `PageMenu/` и `PageRowMenu/` (свои файлы); US5 — `Backlinks/`, `PageHeader/BacklinksRow.swift`; US6 — `PageVersions/`, `PageTreeOperations+RestoreVersion.swift`, `PageEditor/VersionPreview/`, `App/MainWindow/VersionHistory/`. **Пересечения**: `MainWindowModel.swift` (US4 — открыть копию, US6 — показ истории). US6 берёт `movedFrom` из `BlockCopier` этапа 0 и не ждёт US4.
- **D**: US7 один. Зависит от `PageBranchCopier` (A), реестров (A) и окна выбора нет — независим от US4 по коду, но вливается после C, чтобы проверить шаблоны вместе с дублированием.

### Внутри фазы

Тесты → убедиться, что красные по нужной причине → модель и операции → вид → выгрузка → галерея и замер → затронутые тесты зелёные → коммит. Полный прогон — один раз, T102.

### Вливание

Результаты волны вливаются в `003-pages-navigation` по одному, после каждого — затронутые тесты; конфликты решает главный агент; затем `git worktree remove`.
Проверяющих зовёт главный агент; замечания уходят тому же исполнителю.

## Parallel Example: User Story 6

```text
Агент US6 пишет тесты одновременно (разные файлы):
T075 PageSnapshotTests.swift
T076 PageVersionRecorderTests.swift
T077 VersionPruningTests.swift
T078 VersionDiffTests.swift
T079 VersionRestoreTests.swift
T080 UITests/VersionHistoryTests.swift
```

## Implementation Strategy

### MVP

Волна A → US1 → **стоп и проверка**: обложки, широкая страница и мелкий шрифт работают, переживают перезапуск и синхронизацию; замеры в норме.

### Наращивание

Волна B целиком (US1–US3) → волна C (US4–US6) → US7 → итог. Каждая фаза — работающая сборка в виртуальном Mac, коммит, результаты затронутых проверок и замеров.
Оценки времени — plan.md, «Этапы»: A ≈ 3 ч, B ≈ 2,5 ч, C ≈ 2,5 ч, D ≈ 1,5 ч, E ≈ 2,5 ч работы агентов; с правками, как в 002, — 12–14 ч.
Если Юрий выберет другой вариант по истории версий или шаблонам — меняются только фазы 8 и 9 (и, для истории на сервере, добавляется этап сервера в волну C).
