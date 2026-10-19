---

description: "Задачи: новые блоки и оформление текста"
---

# Tasks: Новые блоки и оформление текста

**Input**: Design documents from `/specs/002-rich-blocks-text/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Обязательны — конституция, принцип VI (TDD): в каждой фазе тесты пишутся первыми и должны упасть по нужной причине, затем код, затем зелёные все затронутые.

**Organization**: Фазы идут волнами A–D из plan.md. Каждая история — законченный срез: редактор, отмена, синхронизация, выгрузка, импорт, галерея, замер.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: можно параллельно внутри фазы (другие файлы, нет зависимости от незавершённых задач)
- **[Story]**: история из spec.md (US1…US6)

## Path Conventions

- `PK` = `Packages/MyNotionKit`; модули — `PK/Sources/<Модуль>/`, тесты модулей — `PK/Tests/<Модуль>Tests/`
- Сценарии — `UITests/`, замеры — `PerformanceTests/`, сервер — `server/`, приложение — `App/`
- Всё живое (UI-тесты, замеры, галерея) — только в виртуальном Mac: `scripts/vm/run-in-vm.sh uitest|gallery|run`. На основном Mac — только сборка и `swift test`

---

## Phase 1: Setup — волна A, агент «Фундамент»

**Purpose**: новые модули и места для файлов «по типу блока», чтобы параллельные этапы добавляли файлы, а не правили общие

- [x] T001 В `PK/Package.swift` добавить цели и тестовые цели: `CodeHighlighting` (без зависимостей), `MathRendering` (без зависимостей, ресурс — шрифт), `Attachments` (NotesCore, Sync, GRDB), `LinkPreview` (без зависимостей), `Reminders` (NotesCore, GRDB), `EmbeddedMedia` (VisualStyle); `PageEditor` получает зависимости `CodeHighlighting` и `MathRendering`, остальные тяжёлые модули редактор видит только через протоколы фабрик (plan.md, Structure Decision); создать пустые папки `PK/Sources/PageEditor/{BlockKinds,BlockViewHost,Collapsing,Flows,Table,Inline,PageFind}/`
- [x] T002 В `project.yml` подключить новые модули к приложению `MyNotion`; проверить `xcodegen generate && xcodebuild build -scheme MyNotion` на основном Mac

---

## Phase 2: Foundational (этап 0) — волна A, агент «Фундамент»

**Purpose**: пробы рисков, модель блока v6, потоки, формат синхронизации v2, реестр типов, вид-вложение. ⚠️ Ни одна история не начинается до конца фазы.

### Пробы рисков (первыми, research R16)

- [x] T003 Проба свёртывания в `PerformanceTests/Probes/CollapseProbeTests.swift` + черновой `PK/Sources/PageEditor/Collapsing/HiddenParagraphs.swift` (`NSTextContentManagerDelegate.textContentManager(_:shouldEnumerate:options:)`): страница 1 000 блоков, переключатель с 200 детьми свёрнут; набор рядом p95 ≤ 50 мс; ⌘Z/⇧⌘Z правок до и после свёртывания возвращают нужный текст; ⇧+стрелки через свёрнутое, ⌫ в начале блока под ним, программное выделение внутри скрытого — без падений и потерь; прогон `scripts/vm/run-in-vm.sh uitest --release -only-testing:PerformanceTests/CollapseProbeTests`
- [x] T004 [P] Проба длинного кода в `PerformanceTests/Probes/LongCodeTypingProbeTests.swift`: один абзац 500 строк Swift (переносы U+2028), раскраска заглушкой через `NSTextLayoutManager.setRenderingAttributes` на каждой правке; набор в середине p95 ≤ 50 мс (SC-103)
- [x] T005 [P] Проба видов-вложений в `PerformanceTests/Probes/AttachmentViewsProbeTests.swift`: 50 абзацев с `NSTextAttachmentViewProvider` (вид 720 × 300) среди 1 000 блоков; прокрутка p95 ≤ 50 мс; живых видов не больше видимых + запас раскладки; смена высоты одного вида перекладывает только его абзац
- [x] T006 Записать итоги T003–T005 в `specs/002-rich-blocks-text/research.md` (R16, с датой и цифрами) и `quickstart.md`; при провале пункта зафиксировать запасной путь (R1: нулевая высота строк; R5: блок кода — свой встроенный редактор) до начала US1 и US4; коммит «Этап 0: пробы TextKit 2»

### Тесты фундамента (до кода, должны быть красными)

- [x] T007 [P] Тест миграции v6 в `PK/Tests/NotesCoreTests/DatabaseMigrationTests.swift`: эталон v5 → v6 — все блоки, тексты, оформление, конфликты, очередь исходящих на месте; в `fieldClocks` ключ `sortKey` стал `placement`; новые колонки `containerId`, `color`, `props` (`NOT NULL DEFAULT '{}'`) и таблицы `attachment`, `reminder_state`, `reminder_index`, `block_view_state`; копия `MyNotion.backup-v5.sqlite` и восстановление из неё; повтор миграции ничего не меняет; база новее приложения (`hasBeenSuperseded`) — запись не идёт, ошибка «База от новой версии MyNotion»
- [x] T008 [P] Тест модели в `PK/Tests/NotesCoreTests/BlockModelTests.swift`: все типы из data-model.md; `props` по типам, неизвестные ключи сохраняются при записи; `changedFields` различает `placement`, `color`, `props`; правило глубины дословно: «Глубина ≤ глубина соседа сверху + 1, если сосед — пункт, чекбокс, переключатель, выноска или цитата; иначе 0. Заголовок глубже 0 — только внутри переключателя, выноски или цитаты. Больше допустимого (после слияния) при показе урезается»; `AttachmentRef.byteCount` «≤ 104 857 600»
- [x] T009 [P] Тест оформления в `PK/Tests/NotesCoreTests/InlineTextStylesTests.swift`: `textColor`, `backgroundColor` — «один на символ (как link)»; `mention`, `date`, `equation` — «ровно на одном знаке U+FFFC»; `normalized()` сливает цвета, отбрасывает атом без U+FFFC и U+FFFC без атома; кодирование JSON по contracts/sync-and-files-api.md
- [x] T010 [P] Тест потоков в `PK/Tests/NotesCoreTests/PageFlowsTests.swift`: `PageDocument.blocks` — только поток страницы; `flow(containerId)` по `sortKey`; правка в потоке колонки не трогает поток страницы; автосохранение пишет блоки всех потоков; сирота (контейнер удалён или не пришёл) показывается «в потоке страницы сразу за своим columnList или table, а без них — в конце страницы», запись не меняется; удаление контейнера помечает всё внутри одной правкой
- [x] T011 [P] Тест формата v2 в `PK/Tests/SyncTests/SyncPayloadV2Tests.swift`: кодирование и разбор `placement`, `color`, `props`, сущности `reminder`, новых оформлений; `formatVersion` 2; пачка v1 с `sortKey` читается как `placement` с прежним контейнером; Mac с `currentFormatVersion` 1 пачку v2 не применяет и ждёт
- [x] T012 [P] Тест слияния в `PK/Tests/SyncTests/ChangeMergerV2Tests.swift`: «позднее побеждает» для `placement`, `color`, `props`, `reminder.doneAt`; удаление строки или столбца таблицы, не видевшее правку ячейки, отменяется — строка возвращается; блок в удалённой колонке не теряется; снимок v2 со всеми потоками
- [x] T013 [P] Тест реестра типов в `PK/Tests/PageEditorTests/BlockKindRegistryTests.swift`: у каждого `BlockKind` есть описатель; меню «/», быстрые символы, рисование маркера, запись Markdown, разбор Notion и состояния галереи собираются из описателей; блоки 001 ведут себя как раньше (все тесты `PageEditorTests` 001 зелёные)
- [x] T014 [P] Тест вида-вложения в `PK/Tests/PageEditorTests/BlockViewHostTests.swift`: абзац блока без текста — один U+FFFC и перевод строки; мэппер берёт текст и свойства таких блоков из документа, не со страницы; курсор не встаёт внутрь — перешагивает в сторону движения; щелчок по виду — режим выделения блоков; ⌘Z удаления такого блока возвращает его

### Код фундамента

- [x] T015 Модель в `PK/Sources/NotesCore/Model/Block.swift`, новые `BlockProps.swift`, `NotionColor.swift`, `AttachmentRef.swift`, `DateMention.swift`: типы, `containerId`, `color`, `props`, поля часов `placement`, `color`, `props` строго по data-model.md; `BlockDraft` в `PK/Sources/NotesCore/Document/PageDocument.swift` получает те же поля
- [x] T016 Оформление в строке в `PK/Sources/NotesCore/Model/InlineText.swift` (T009)
- [x] T017 Миграция v6 в `PK/Sources/NotesCore/Storage/SchemaMigrations.swift` (пересоздание `block` с новым `CHECK`, колонки, индекс `block_by_container(containerId, sortKey) WHERE containerId IS NOT NULL`, четыре таблицы), чтение и запись в `RowMapping.swift`, `NotesTransaction.swift`, отказ писать в базу новее себя в `AppDatabase.swift` (T007)
- [x] T018 Потоки в `PK/Sources/NotesCore/Document/PageDocument.swift` и новом `PK/Sources/NotesCore/Document/BlockFlow.swift`: один словарь блоков по id, списки id по потокам, `flow(containerId)`, `replaceBlocks` внутри потока, правило сирот (T010)
- [x] T019 Синхронизация v2: `PK/Sources/Sync/SyncPayload.swift`, `Outbox.swift`, `ChangeMerger.swift`, `SyncSnapshot.swift`, `BatchCipher.swift` (T011, T012); сущность `reminder` только переносится, применение — в US3
- [x] T020 Реестр типов в `PK/Sources/PageEditor/BlockKinds/BlockKindDescriptor.swift` и `BlockKindRegistry.swift`; перевести на него `SlashCommandMenu.swift`, `MarkdownShortcuts.swift`, `decoration(for:)` в `BlockLayoutFragment.swift`; в `BlockLayoutFragment` — точка «рисователей» по типу (`BlockPainters/`: подложка блока, черта, рамка), чтобы US1 и US2 писали свои файлы; точки расширения в `PK/Sources/MarkdownExport/BlockWriters/` и `PK/Sources/NotionImport/BlockReaders/`; описатели блоков 001 — по файлу в `BlockKinds/` (T013)
- [x] T021 Вид-вложение в `PK/Sources/PageEditor/BlockViewHost/BlockAttachment.swift`, `BlockAttachmentViewProvider.swift`; правило курсора в `PageTextView.setSelectedRanges`; мэппер `PageTextStorageMapper.swift` — блоки без текста, атрибуты `color` и `props` абзаца; протоколы фабрик видов `BlockViewFactories.swift` (T014)
- [x] T022 [P] Эталонная «богатая» страница в `PK/Sources/NotesCore/Fixtures/RichPageGenerator.swift` (состав — quickstart.md; каждый тип добавляет свою часть через описатель), флаг `--generate-rich-sample` в `App/MyNotionApp.swift`; состояния галереи из описателей в `PK/Sources/UIGallery/GalleryCatalog.swift`
- [x] T023 Затронутые тесты зелёные (`swift test`); замер запуска и памяти в виртуальном Mac (`scripts/vm/run-in-vm.sh uitest --release -only-testing:PerformanceTests/LaunchAndMemoryTests`) не хуже 001 (0,36–0,48 с, 46 МБ); запись в quickstart.md, раздел «Этап 0»; коммит

**Checkpoint**: фундамент готов — волна B стартует.

---

## Phase 3: Сервер файлов (этап S) — волна A, агент «Сервер», параллельно фазе 2 [US5]

**Goal**: хранилище зашифрованных частей файлов по contracts/sync-and-files-api.md. Правит только `server/`.

**Independent Test**: `cd server && pnpm test` — все случаи контракта; после развёртывания `GET /files/usage` с токеном → 200.

- [x] T024 [P] [US5] Тесты в `server/test/files.test.ts`: `PUT /files/{id}/parts/{n}?count=` — 201, повтор 200, часть больше «8 МБ + 28 байт» — 413, несовпадающий `count` или `index ≥ count` — 400, после `complete` — 409 `file_complete`, квота — 507 `storage_full`; `GET /files/{id}` — список частей и `complete`; `POST …/complete` — 200 или 400 `{missing}`; `GET …/parts/{n}` до сборки — 409 `file_incomplete`; `DELETE` — 204, повтор 204, затем `GET` 404; отправка части в файл из корзины достаёт его и стирает прежние части; оборванная запись части не оставляет файла; `GET /files/usage`; без токена — 401
- [x] T025 [P] [US5] Тесты в `server/test/backup.test.ts`: копия `backups/files-<дата>` жёсткими ссылками, 14 копий; уборка: корзина старше 30 дней и несобранные без новых частей 7 дней стираются
- [x] T026 [US5] `server/src/files.ts` и таблица `files (id, part_count, bytes, complete_at, deleted_at, created_at)` в `server/src/db.ts`; части в `/data/files/<2 знака id>/<id>/<index>.part` через временный файл и переименование; квота `FILES_LIMIT_GB` (по умолчанию 50) в `server/src/config.ts`
- [x] T027 [US5] Маршруты в `server/src/app.ts` (тело `application/octet-stream`, свой предел), суточная уборка в `server/src/main.ts`, копия файлов в `server/src/backup.ts`; `pnpm test` и `pnpm typecheck` зелёные; коммит
- [ ] T028 [US5] Развёртывание на `mynotion.kurilov.cloud` по скиллу server-deploy: `client_max_body_size` ≥ 9 МБ, тайм-аут чтения тела 120 с, том `./data/files`; проверка `/health` и `GET /files/usage`; ссылка и итог — в quickstart.md

**Checkpoint**: сервер принимает файлы; приложение подключится в US5.

---

## Phase 4: User Story 1 — Структурные блоки (P1) 🎯 MVP — волна B, агент «US1»

**Goal**: переключатель, цитата, выноска, разделитель; вложенность; свёртывание.

**Independent Test**: создать все четыре блока через «/» и быстрые символы, вложить блоки в переключатель и выноску, свернуть/развернуть, перезапустить — всё на месте (spec US1).

### Тесты

- [x] T029 [P] [US1] `PK/Tests/PageEditorTests/StructuralBlockTests.swift`: `> `, `" `, `---`, «/» → «Выноска»; Tab под переключателем, выноской, цитатой; Enter в конце раскрытого переключателя — первый ребёнок, в свёрнутом — после детей; Enter в пустом ребёнке — выход на уровень; ⌫ в начале — абзац, дети поднимаются; заголовок вкладывается только внутрь переключателя, выноски, цитаты; ⌘Z каждого шага
- [x] T030 [P] [US1] `PK/Tests/PageEditorTests/CollapsingTests.swift`: скрытые абзацы не раскладываются; курсор, попавший внутрь, уходит к концу строки переключателя; ⌫ под свёрнутым склеивает с текстом переключателя; выделение через свёрнутое захватывает детей; выделение внутрь скрытого раскрывает всех предков; ⌘Enter и ⌘⌥T; ⌘Z/⇧⌘Z не задеты свёртыванием
- [x] T031 [P] [US1] `PK/Tests/NotesCoreTests/BlockViewStateTests.swift`: свёрнутость пишется сразу в `block_view_state`, переживает перезапуск, не попадает в очередь исходящих и в отмену
- [x] T032 [P] [US1] `PK/Tests/MarkdownExportTests/StructuralBlocksExportTests.swift` и `PK/Tests/NotionImportTests/StructuralBlocksImportTests.swift`: `<details>`/`<summary>`, `<aside data-icon>`, `>` с детьми, `---` по contracts/markdown-and-notion.md; выгрузка → импорт — те же блоки; выгрузка Notion: `<details>`, `<aside>`, `>` больше не «упрощены»
- [x] T033 [P] [US1] `UITests/StructuralBlocksTests.swift`: сценарий Independent Test + поиск страниц (⇧⌘F) по слову в свёрнутом раскрывает до найденного

### Код

- [x] T034 [US1] Описатели `PK/Sources/PageEditor/BlockKinds/Toggle.swift`, `Quote.swift`, `Callout.swift`, `Divider.swift`: меню «/» и слова поиска, быстрые символы, клавиши по contracts/blocks-and-keys.md
- [x] T035 [US1] Свёртывание `PK/Sources/PageEditor/Collapsing/CollapsedParagraphs.swift` (из пробы T003 или её запасного пути), правила курсора и ⌫ в `PageTextView.swift`, раскрытие предков при выделении внутри скрытого; чтение и запись `block_view_state` через `PK/Sources/NotesCore/Storage/BlockViewStateStore.swift`
- [x] T036 [US1] Правило глубины в `PK/Sources/PageEditor/BlockMoveController.swift` и `BlockDraft.apply` (`PageDocument.swift`): кто может иметь детей, заголовок внутри контейнеров
- [x] T037 [P] [US1] Рисователи `PK/Sources/PageEditor/BlockPainters/TogglePainter.swift` (▸/▾), `QuoteBarPainter.swift`, `CalloutBoxPainter.swift` (по поддереву), разделитель — вид-вложение высотой 13; размеры в `PK/Sources/VisualStyle/Metrics.swift`
- [x] T038 [US1] Иконка выноски — окно эмодзи 001 без «Убрать» (`PK/Sources/EmojiPicker/`); `props.icon` по умолчанию 💡, фон gray в `color`
- [x] T039 [US1] Переход к найденному из поиска страниц раскрывает свёрнутых предков: `App/MainWindow/MainWindowModel.swift`
- [x] T040 [P] [US1] Выгрузка `PK/Sources/MarkdownExport/BlockWriters/StructuralBlockWriters.swift`, импорт `PK/Sources/NotionImport/BlockReaders/StructuralBlockReaders.swift`; убрать «упрощено» для цитаты, выноски, переключателя, разделителя
- [x] T041 [US1] Галерея (`scripts/vm/run-in-vm.sh gallery --only structural`) в обеих темах, сверка с живым Notion, цифры — в contracts/blocks-and-keys.md; замер набора на «богатой» странице p95 ≤ 50 мс; затронутые тесты зелёные; коммит

**Checkpoint**: US1 работает сам по себе — MVP.

---

## Phase 5: User Story 2 — Цвет текста и фона (P2) — волна B, агент «US2»

**Goal**: 10 цветов Notion в строке и у блока, в обеих темах.

**Independent Test**: покрасить слово, фон слова, целый блок; перезапуск; выгрузка в Markdown — цвет есть в приложении и в выгрузке (spec US2).

### Тесты

- [x] T042 [P] [US2] `PK/Tests/PageEditorTests/InlineColorTests.swift`: цвет текста и фона на выделении, через блоки; повтор того же цвета снимает; ⌘⇧H — последний цвет; ⌘Z; вид — динамический цвет палитры
- [x] T043 [P] [US2] `PK/Tests/PageEditorTests/BlockColorTests.swift`: «⋮⋮» → «Цвет» для всех типов, включая списки и заголовки; подложка во всю ширину блока; цвет в строке главнее цвета блока
- [x] T044 [P] [US2] `PK/Tests/VisualStyleTests/NotionPaletteTests.swift`: 10 цветов × текст/фон × светлая/тёмная — значения из contracts/blocks-and-keys.md (после сверки с Notion)
- [x] T045 [P] [US2] `PK/Tests/MarkdownExportTests/ColorExportTests.swift` и импорт своей выгрузки: `<span data-color>`, `<mark data-color>`, вложенные, `<!-- mynotion:color … -->` перед блоком
- [x] T046 [P] [US2] `UITests/ColorTests.swift`: сценарий Independent Test; снимки в обеих темах

### Код

- [x] T047 [US2] Палитра `PK/Sources/VisualStyle/Palette.swift` (`NotionColor` → динамические `NSColor`), значения сняты с живого Notion в обеих темах
- [x] T048 [US2] Цвета в строке `PK/Sources/PageEditor/Inline/InlineColors.swift` + отображение в `PageTextStorageMapper.swift` (`inlineRendering`)
- [x] T049 [US2] Окно цветов `PK/Sources/PageEditor/Inline/ColorMenu.swift` («Последние», «Цвет текста», «Цвет фона»), кнопка «A» в `PK/Sources/PageEditor/FormatBar.swift`, ⌘⇧H в `App/Commands/FormatCommands.swift`
- [x] T050 [US2] «Цвет» в меню блока (`PK/Sources/PageEditor/BlockHandlesOverlay.swift`) и рисователь `PK/Sources/PageEditor/BlockPainters/BlockBackgroundPainter.swift`
- [x] T051 [P] [US2] Выгрузка и импорт `PK/Sources/MarkdownExport/InlineMarkdown.swift`, `BlockWriters/ColorWriter.swift`, `PK/Sources/NotionImport/NotionInlineParser.swift`
- [x] T052 [US2] Галерея в обеих темах, сверка с Notion; затронутые тесты зелёные; коммит

---

## Phase 6: User Story 3 — Упоминания, даты, напоминания (P3) — волна B, агент «US3»

**Goal**: «@» и «[[», даты с календариком, напоминания macOS на всех Mac без дублей.

**Independent Test**: упомянуть страницу, переименовать её — упоминание обновилось; дата «завтра» с напоминанием — в нужное время уведомление macOS (spec US3).

### Тесты

- [x] T053 [P] [US3] `PK/Tests/PageEditorTests/MentionTests.swift`: «@» и «[[» открывают окно, выбор вставляет U+FFFC с `mention`; название и иконка из справочника, обновляются при переименовании; корзина — «Удалённая страница», нет на Mac — «Страница загружается»; курсор перешагивает, ⌫ удаляет целиком; простой текст — название
- [x] T054 [P] [US3] `PK/Tests/PageEditorTests/DateQueryTests.swift`: «сегодня», «завтра», «вчера», «через неделю», «25 окт», «25.10», «25.10.2026», «25 октября 14:30»; показ «Сегодня», «Завтра», «20 октября 2026», «9:00»; часовой пояс
- [x] T055 [P] [US3] `PK/Tests/RemindersTests/ReminderIndexTests.swift`: индекс обновляется в той же транзакции, что текст; блок удалён, страница в корзине, дата стёрта — напоминание снято; вставка копии даты — новый id, ⌘Z — прежний
- [x] T056 [P] [US3] `PK/Tests/RemindersTests/ReminderSchedulerTests.swift` с подменёнными часами и центром уведомлений: ставятся ближайшие 50 несделанных; идентификатор = id упоминания, повтор не дублирует; после «пробуждения» просроченные за 7 дней показываются сразу один раз; `doneAt` снимает доставленное и запланированное
- [x] T057 [P] [US3] `PK/Tests/SyncTests/ReminderSyncTests.swift`: `reminder.doneAt` сходится на двух Mac; «Готово» на одном снимает уведомление на другом
- [x] T058 [P] [US3] Выгрузка и импорт упоминаний и дат: `PK/Tests/MarkdownExportTests/MentionDateExportTests.swift` (`<time datetime data-remind>`, ссылка на файл страницы) и `PK/Tests/NotionImportTests/MentionDateImportTests.swift` (`@October 20, 2026`, ссылки на страницы выгрузки внутри текста — упоминания)
- [x] T059 [P] [US3] `UITests/MentionsAndDatesTests.swift`: сценарий Independent Test (напоминание через подменённые часы приложения), щелчок по уведомлению открывает страницу у блока

### Код

- [x] T060 [US3] Справочник страниц `PK/Sources/PageEditor/Inline/MentionDirectory.swift` и вложение-картинка `MentionAttachment.swift`; поиск страниц для окна — протокол `PageLookup`, реализация через FTS5 в `App/`
- [x] T061 [US3] Окно «@»/«[[» `PK/Sources/PageEditor/Inline/MentionPicker.swift` (по образцу `SlashCommandMenu.swift`)
- [x] T062 [US3] Даты `PK/Sources/PageEditor/Inline/DateQuery.swift`, `DateMentionAttachment.swift`, календарик `DatePickerPopover.swift` с «Напомнить» по contracts/blocks-and-keys.md
- [x] T063 [US3] Модуль `PK/Sources/Reminders/`: `ReminderIndexer.swift` (хук транзакции), `ReminderScheduler.swift` (обёртка `UNUserNotificationCenter` за протоколом), наблюдение `NSWorkspace.didWakeNotification`; перепланирование — после готовности редактора, не при запуске
- [x] T064 [US3] `App/Notifications/ReminderNotifications.swift`: делегат уведомлений, кнопка «Готово», открытие страницы у блока, запрос разрешения при первом «Напомнить», подсказка при отказе
- [x] T065 [US3] Применение `reminder` в `PK/Sources/Sync/ChangeMerger.swift` и `Outbox.swift`
- [x] T066 [P] [US3] Выгрузка и импорт: `PK/Sources/MarkdownExport/InlineMarkdown.swift`, `PK/Sources/NotionImport/NotionInlineParser.swift`
- [x] T067 [US3] Галерея, опоздание напоминания ≤ 1 мин (SC-104) в виртуальном Mac; затронутые тесты зелёные; коммит

---

## Phase 7: User Story 4 — Код, формулы, оглавление (P4) — волна C, агент «US4»

**Goal**: блок кода с подсветкой 24 языков, формулы блоком и в строке, оглавление.

**Independent Test**: блок кода с языком подсвечен; формула в строке и блоком отрисована; оглавление обновляется при правке заголовков и ведёт к ним (spec US4).

### Тесты

- [ ] T068 [P] [US4] `PK/Tests/CodeHighlightingTests/HighlighterTests.swift`: по образцу на каждый из 24 языков (research R5) — ключевые слова, строки, числа, комментарии; многострочный комментарий и строка через правку; перекраска останавливается, когда состояние конца строки совпало; полный разбор 500 строк — замер
- [ ] T069 [P] [US4] `PK/Tests/PageEditorTests/CodeBlockEditingTests.swift` (блок кода — встроенный редактор внутри вида-вложения, строка кода — свой абзац; research R5 «Решение 19.10.2026»): ```` ``` ```` создаёт блок-вложение с редактором и курсором в нём; правка в редакторе кода пишет `text` блока (строки через `\n`) и отменяется общим ⌘Z окна; ↑ на первой строке и ↓ на последней — в соседний блок страницы; Enter — строка внутри; Tab — два пробела, у выделения — у каждой строки; ⇧Tab; ⌘Enter — абзац под блоком; ↓ на последней строке; «/» и быстрые символы внутри не работают; «Копировать» — весь код; цвета — атрибуты показа, не в тексте и не в отмене
- [ ] T070 [P] [US4] `PK/Tests/MathRenderingTests/FormulaRenderingTests.swift`: дроби, корни, индексы, матрицы, `aligned`, `cases`; ошибка — признак «Неверная формула», запись цела; кэш по (запись, размер, тема); шрифт грузится при первой формуле
- [ ] T071 [P] [US4] `PK/Tests/PageEditorTests/EquationTests.swift`: формула-блок и в строке (⌃⇧E, кнопка «√x»), окно правки: Enter, ⇧Enter, Esc; пустая — «Новая формула»
- [ ] T072 [P] [US4] `PK/Tests/PageEditorTests/TableOfContentsTests.swift`: строки заголовков с отступами; правка заголовка обновляет; щелчок прокручивает и раскрывает свёрнутых предков; без заголовков — подсказка
- [ ] T073 [P] [US4] Выгрузка и импорт кода, `$$`, `$…$`, `<nav data-toc>`: `PK/Tests/MarkdownExportTests/CodeMathExportTests.swift`, `PK/Tests/NotionImportTests/CodeMathImportTests.swift` (язык из ограды; незнакомый — `plain` и строка в отчёте)
- [ ] T074 [P] [US4] `UITests/CodeMathTocTests.swift`: сценарий Independent Test

### Код

- [ ] T075 [US4] Модуль `PK/Sources/CodeHighlighting/`: `LanguageDefinition.swift`, `Languages/*.swift` (24 таблицы), `LineScanner.swift`, `IncrementalHighlighter.swift`
- [ ] T076 [US4] Блок кода — встроенный редактор (research R5, «Решение 19.10.2026»; проба T004 провалилась: один абзац на 500 строк TextKit 2 перекладывает за 310 мс): `PK/Sources/PageEditor/BlockKinds/Code.swift` (описатель, фабрика вида через `BlockViewFactories`), `PK/Sources/PageEditor/BlockKinds/CodeBlockEditor.swift` (свой `NSTextView` на TextKit 2, строка кода — абзац; запись в документ по правке; клавиши кода; переходы курсора к соседним блокам страницы; общий `UndoManager` окна) и `CodeBlockChrome.swift` (язык с поиском, «Копировать» / «Скопировано»); раскраска через `setRenderingAttributes` встроенного редактора. `BlockKind.code` уже абзац-вложение (`rendersAsAttachment`, этап 0)
- [ ] T077 [US4] Модуль `PK/Sources/MathRendering/`: исходники SwiftMath 1.7.3 (MIT, `LICENSE` рядом) с одним шрифтом `latinmodern-math.otf`; `FormulaImageCache.swift`
- [ ] T078 [US4] `PK/Sources/PageEditor/BlockKinds/Equation.swift`, `PK/Sources/PageEditor/Inline/InlineEquationAttachment.swift`, `EquationEditorPopover.swift`; кнопка «√x» в `FormatBar.swift`
- [ ] T079 [US4] `PK/Sources/PageEditor/BlockKinds/TableOfContents.swift`: вид по уведомлению о правке документа
- [ ] T080 [P] [US4] Выгрузка и импорт: `PK/Sources/MarkdownExport/BlockWriters/CodeMathWriters.swift`, `PK/Sources/NotionImport/BlockReaders/CodeMathReaders.swift`
- [ ] T081 [US4] Галерея в обеих темах, сверка с Notion; набор в середине блока кода на 500 строк p95 ≤ 50 мс (SC-103) — в виртуальном Mac, по образцу `PerformanceTests/Probes/LongCodeTypingProbeTests.swift`, но во встроенном редакторе кода; размер сборки до и после `MathRendering`; затронутые тесты зелёные; коммит

---

## Phase 8: User Story 5 — Картинки, файлы, видео, закладки (P5) — волна C, агент «US5»

**Goal**: вложения с копией на Mac и передачей через сервер (фаза 3), блоки картинки, файла, видео, закладки.

**Independent Test**: картинка из Finder и из буфера, PDF, видео, закладка; перезапуск — файлы на месте и открываются; второй Mac получает файлы (spec US5).

### Тесты

- [ ] T082 [P] [US5] `PK/Tests/AttachmentsTests/AttachmentStoreTests.swift`: копия в `Attachments/<id>/<имя>`, оригинал не тронут; удаление оригинала в Finder — копия открывается; больше 100 МБ — ошибка, блок не создаётся; ссылки пересчитываются в транзакции, сирота получает `orphanedAt`, возврат ссылки его снимает; стирание — только сирота старше 30 дней, когда все устройства знают удаление
- [ ] T083 [P] [US5] `PK/Tests/AttachmentsTests/FileCipherTests.swift`: ключ HKDF-SHA256 (соль — id файла, `mynotion-file-v1`); части по 8 388 608 байт; подмена, перестановка и обрезка части не расшифровываются; сверка SHA-256
- [ ] T084 [P] [US5] `PK/Tests/AttachmentsTests/AttachmentTransferTests.swift` с файлами в `PK/Tests/SyncTests/Support/FakeSyncServer.swift`: отправка по частям и докачка с первой отсутствующей; пачка с блоком не ждёт файла; скачивание по одному, файлы открытой страницы первыми; `409 file_incomplete` и `404` — повтор 1, 2, 4 … 60 мин; `507` — сообщение, файл цел; выключение синхронизации файлы не трогает
- [ ] T085 [P] [US5] `PK/Tests/LinkPreviewTests/LinkPreviewTests.swift`: `og:title|description|image`, `<title>`, `<link rel="icon">` на образцах; предел 512 КБ и 10 с; oEmbed YouTube и Vimeo; без сети — только адрес
- [ ] T086 [P] [US5] `PK/Tests/PageEditorTests/MediaBlocksTests.swift`: картинка по ширине колонки, ширина 10–100 %, подпись в `text`; заглушки «Загружается…» и «Ждёт отправки с другого Mac»; блок-файл — значок, имя, размер; меню вставки ссылки YouTube «Встроить видео / Закладка / Ссылка»
- [ ] T087 [P] [US5] Выгрузка и импорт: `PK/Tests/MarkdownExportTests/AttachmentsExportTests.swift` (копии в папке страницы, « (2)» при совпадении, `[файл не скачан: …]` и итог), `PK/Tests/NotionImportTests/AttachmentsImportTests.swift` (картинки и файлы из выгрузки — вложения; больше 100 МБ или нет файла — «[файл: имя]»; ссылки YouTube/Vimeo — видео; одиночная ссылка — закладка)
- [ ] T088 [P] [US5] `UITests/MediaBlocksTests.swift`: сценарий Independent Test, удаление оригинала, сообщение о 100 МБ

### Код

- [ ] T089 [US5] Модуль `PK/Sources/Attachments/`: `AttachmentStore.swift`, `AttachmentReferenceCounter.swift` (хук транзакции), `FileCipher.swift`, `AttachmentCollector.swift` (30 дней, `DELETE /files/{id}`)
- [ ] T090 [US5] Передача `PK/Sources/Attachments/AttachmentTransfer.swift` и эндпоинты файлов в `PK/Sources/Sync/SyncClient.swift`; запуск очереди из `SyncEngine.swift` только при непустой очереди
- [ ] T091 [US5] `PK/Sources/PageEditor/BlockKinds/Image.swift`, `ImageThumbnailCache.swift` (ImageIO, до 48 МБ, вытесняемый), ширина и подпись
- [ ] T092 [US5] `PK/Sources/PageEditor/BlockKinds/File.swift`: двойной щелчок — программа по умолчанию, «Показать в Finder», «Скачать копию…», «Переименовать»
- [ ] T093 [US5] Модуль `PK/Sources/EmbeddedMedia/`: `VideoFilePlayerView.swift` (`AVPlayerView` по нажатию, первый кадр), `WebVideoPlayerView.swift` (`WKWebView` по нажатию, один на окно, закрытие вне экрана); `PK/Sources/PageEditor/BlockKinds/Video.swift`
- [ ] T094 [US5] Модуль `PK/Sources/LinkPreview/` и `PK/Sources/PageEditor/BlockKinds/Bookmark.swift` (картинка и значок — вложениями, «Обновить»)
- [ ] T095 [US5] Вставка: перетаскивание из Finder, ⌘V картинки, окно «Выбрать файл… / Вставить ссылку» — `PK/Sources/PageEditor/BlockViewHost/AttachmentInsertion.swift`; фабрики видов — в `App/MainWindow/`
- [ ] T096 [US5] Место файлов и квота сервера в `App/Settings/SyncSettingsView.swift` (`GET /files/usage`)
- [ ] T097 [P] [US5] Выгрузка и импорт: `PK/Sources/MarkdownExport/BlockWriters/AttachmentWriters.swift`, `PK/Sources/NotionImport/BlockReaders/AttachmentReaders.swift`
- [ ] T098 [US5] Галерея; память в покое после просмотра и закрытия YouTube — исходная ± 10 МБ, память во время игры — записать для Юрия; прокрутка «богатой» страницы p95 ≤ 50 мс; живая проверка двух Mac, quickstart.md шаги 1–3 и 5; затронутые тесты зелёные; коммит

---

## Phase 9: User Story 6 — Таблицы и колонки (P6) — волна C, агент «US6»

**Goal**: простая таблица, колонки 2–5, ⌘F по всей странице.

**Independent Test**: таблица 3×3 с заголовочной строкой, добавить строку и столбец; перетащить блок к правому краю другого — две колонки; перезапуск — всё на месте (spec US6).

### Тесты

- [x] T099 [P] [US6] `PK/Tests/NotesCoreTests/TableModelTests.swift`: таблица = `table` + `tableColumn` + `tableRow` + `tableCell`; «отсутствующая ячейка — пустая, создаётся при первом вводе»; ячейка удалённого столбца не показывается; «удаление последнего удаляет таблицу»
- [x] T100 [P] [US6] `PK/Tests/PageEditorTests/TableEditingTests.swift`: «/» → 3 × 2, Tab / ⇧Tab, Tab в последней — строка, стрелки на краю ячейки, Enter, Esc; «+» строка и столбец; вставить выше/ниже/слева/справа; строка и столбец заголовков; ширина столбца; ⌘C — табуляции, ⌘V в ячейки; оформление в ячейке; ⌘Z каждого шага
- [x] T101 [P] [US6] `PK/Tests/PageEditorTests/ColumnsTests.swift`: «⋮⋮» к правому краю — две колонки (цель слева); до 5; граница 10–90 %; пустая колонка исчезает, одна — распадается; ↑ ↓ ← → между колонками и блоками над и под; всё одним шагом ⌘Z
- [ ] T102 [P] [US6] `PK/Tests/PageEditorTests/PageFindTests.swift`: ⌘F находит в потоке страницы, колонке, ячейке и свёрнутом; переход по совпадениям; совпадение в свёрнутом раскрывает его
- [x] T103 [P] [US6] `PK/Tests/SyncTests/TablesColumnsConvergenceTests.swift`: правки разных ячеек на двух Mac — без конфликта; одна ячейка — «Две версии»; перенос блока между колонками одной меткой `placement`; блок удалённой колонки виден за колонками
- [x] T104 [P] [US6] Выгрузка и импорт: `PK/Tests/MarkdownExportTests/TablesColumnsExportTests.swift` (GFM, `<!-- mynotion:table … -->`, `|` и `<br>` в ячейке; `<div data-columns>`), `PK/Tests/NotionImportTests/TablesImportTests.swift` (таблица Markdown Notion — таблица, первая строка — заголовки)
- [ ] T105 [P] [US6] `UITests/TablesAndColumnsTests.swift`: сценарий Independent Test + ⌘F в колонке

### Код

- [x] T106 [US6] Таблица `PK/Sources/PageEditor/Table/TableView.swift` (ячейки через CoreText), `TableCellEditor.swift` (одно поле правки на таблицу, мэппер одного блока), `TableMenus.swift`; `PK/Sources/PageEditor/BlockKinds/Table.swift`
- [x] T107 [US6] Колонки `PK/Sources/PageEditor/Flows/FlowTextView.swift` (редактор потока без шапки, общий `UndoManager` окна), `ColumnsView.swift`, `PK/Sources/PageEditor/BlockKinds/Columns.swift`
- [x] T108 [US6] `PK/Sources/PageEditor/Flows/FlowNavigator.swift`: переходы курсора между редакторами страницы
- [x] T109 [US6] `PK/Sources/PageEditor/Flows/FlowDragCoordinator.swift` и правки `BlockHandlesOverlay.swift`: место сброса над любым редактором, сборка и распад колонок одной правкой
- [ ] T110 [US6] `PK/Sources/PageEditor/PageFind/PageFindClient.swift` (`NSTextFinderClient` по всем потокам и ячейкам) вместо системного поиска одного `NSTextView`
- [ ] T111 [US6] Переход к найденному из поиска страниц в колонку или ячейку: `App/MainWindow/MainWindowModel.swift`
- [x] T112 [P] [US6] Выгрузка и импорт: `PK/Sources/MarkdownExport/BlockWriters/TableColumnsWriters.swift`, `PK/Sources/NotionImport/BlockReaders/TableReaders.swift`
- [ ] T113 [US6] Галерея, сверка с Notion; набор в колонке и в ячейке p95 ≤ 50 мс; затронутые тесты зелёные; коммит

---

## Phase 10: Polish (этап 7) — волна D, один агент

**Purpose**: круговые проверки, живой импорт, единственный полный прогон, замеры, сборка

- [ ] T114 Круговой тест `PK/Tests/NotionImportTests/RichRoundTripTests.swift`: «богатая» страница → выгрузка → импорт — текст 100 %, блоки, оформление и файлы (SHA-256) совпадают (SC-105)
- [ ] T115 Отчёт импорта честно называет потерю (решение Юрия, research R14): в итоге импорта из Notion всегда строка «Цвета и колонки Notion в Markdown не выгружает — они не перенесены» — `PK/Sources/NotionImport/NotionImporter.swift`, `App/Settings/NotionImportView.swift`, тест в `PK/Tests/NotionImportTests/NotionImporterTests.swift`
- [ ] T116 Живая выгрузка Notion Юрия: импорт в виртуальном Mac (`scripts/vm/run-in-vm.sh run --import-notion <путь>`); сверить таблицу импорта в contracts/markdown-and-notion.md с фактом и поправить; сколько формул не разобрал SwiftMath — в research.md R6
- [ ] T117 [P] Создание любого блока через «/» ≤ 3 с набора (SC-101) — `UITests/SlashMenuSpeedTests.swift`
- [ ] T118 Полная галерея `scripts/vm/run-in-vm.sh gallery` в обеих темах; отдельный агент-проверяющий сверяет с живым Notion и contracts/blocks-and-keys.md; каждая найденная кривость — исправление и проверка геометрии в тестах
- [ ] T119 **Единственный полный прогон**: `swift test` всего пакета; все UI-тесты `scripts/vm/run-in-vm.sh uitest`; `cd server && pnpm test`; ни одного красного
- [ ] T120 Полные замеры `scripts/vm/run-in-vm.sh uitest --release` по таблице quickstart.md (запуск, память, набор, переход, прокрутка, код 500 строк, колонка, ячейка) на «богатой» странице и эталоне 001; итоги с датой — в quickstart.md; нарушение бюджета — исправить до слияния
- [ ] T121 Сборка Release (`xcodebuild -scheme MyNotion -configuration Release`), установка в `/Applications` на обоих Mac Юрия с заменой сборки 001 (data-model.md, «Схема v6», п. 5); живая проверка двух Mac — quickstart.md шаги 1–5
- [ ] T122 README: новые модули, флаг `--generate-rich-sample`, сервер файлов; слияние `002-rich-blocks-text` в `main` после согласия Юрия

---

## Dependencies & Execution Order

### Волны и агенты (не больше трёх одновременно, каждый в своём git worktree от `002-rich-blocks-text`)

| Волна | Агент 1 | Агент 2 | Агент 3 | Старт |
|-------|---------|---------|---------|-------|
| **A** | Фундамент: фазы 1–2 (T001–T023) | Сервер файлов: фаза 3 (T024–T028) | — | сразу |
| **B** | US1: фаза 4 (T029–T041) | US2: фаза 5 (T042–T052) | US3: фаза 6 (T053–T067) | после T023 |
| **C** | US4: фаза 7 (T068–T081) | US5: фаза 8 (T082–T098) | US6: фаза 9 (T099–T113) | после вливания B |
| **D** | Polish: фаза 10 (T114–T122) | — | — | после вливания C |

### Почему этапы одной волны независимы (не правят одни файлы)

- **A**: фундамент правит только `PK/`, `project.yml`, `App/`, `PerformanceTests/`; сервер — только `server/`.
- **B**: US1 — `BlockKinds/{Toggle,Quote,Callout,Divider}`, `Collapsing/`, `BlockPainters/{Toggle,QuoteBar,CalloutBox}`, `BlockMoveController`; US2 — `Palette`, `Inline/{InlineColors,ColorMenu}`, `FormatBar`, `BlockPainters/BlockBackgroundPainter`, `BlockHandlesOverlay`; US3 — `Inline/{Mention*,Date*}`, модуль `Reminders`, `App/Notifications/`, `Sync/ChangeMerger` (только `reminder`). Общие места (меню «/», выгрузка, импорт, галерея, генератор) разведены реестром T020: каждый добавляет свои файлы. Пересечения, которые остаются: `PageTextView.swift` (US1 — правила свёрнутого, US3 — «@»/«[[») и `InlineMarkdown.swift`/`NotionInlineParser.swift` (US2 и US3) — разные функции, конфликт при вливании решает главный агент.
- **C**: US4 — `CodeHighlighting`, `MathRendering`, `BlockKinds/{Code,Equation,TableOfContents}`; US5 — `Attachments`, `EmbeddedMedia`, `LinkPreview`, `BlockKinds/{Image,File,Video,Bookmark}`, `SyncClient`, `SyncEngine`, `SyncSettingsView`; US6 — `Table/`, `Flows/`, `PageFind/`, `BlockKinds/{Table,Columns}`, `BlockHandlesOverlay`. Пересечения: `FormatBar.swift` (только US4), `PageTextView.swift` (US4 — клавиши кода, US6 — передача фокуса между потоками), `App/MainWindow/` (US5 — фабрики видов, US6 — переход к найденному).
- US4 и US6 зависят от US1 (вложенность и свёрнутое внутри кода и колонок, раскрытие предков); US5 — от сервера (фаза 3).

### Внутри фазы

Тесты → убедиться, что красные по нужной причине → модель и логика → вид → выгрузка и импорт → галерея и замер → затронутые тесты зелёные → коммит. Полный прогон — один раз, T119.

### Вливание

Результаты волны вливаются в `002-rich-blocks-text` по одному, после каждого — затронутые тесты; конфликты решает главный агент; затем `git worktree remove`.
Проверяющих зовёт главный агент; замечания уходят тому же исполнителю.

## Parallel Example: User Story 6

```text
Агент US6 пишет тесты одновременно (разные файлы):
T099 TableModelTests.swift
T100 TableEditingTests.swift
T101 ColumnsTests.swift
T102 PageFindTests.swift
T103 TablesColumnsConvergenceTests.swift
T104 TablesColumnsExportTests.swift + TablesImportTests.swift
```

## Implementation Strategy

### MVP

Волна A → US1 → **стоп и проверка**: Юрий пишет заметки с переключателями, выносками, цитатами и разделителями; всё переживает перезапуск и синхронизацию; замеры в норме.

### Наращивание

Волна B целиком (US1–US3) → волна C (US4–US6) → этап 7. Каждая фаза — работающая сборка в виртуальном Mac, коммит, результаты затронутых проверок и замеров.
Оценки времени — plan.md, «Этапы»: A ≈ 2,5 ч, B ≈ 2,5 ч, C ≈ 4 ч, D ≈ 2,5 ч работы агентов.
