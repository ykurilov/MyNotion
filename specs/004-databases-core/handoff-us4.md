# Передача: US4 «Связи и сводки» (волна C, T086–T094)

**Итог 23.10.2026:** T086–T094 подтверждены; RelationRollupTests PASS 65,886 с, галерея 18/18
визуально проверена в двух темах, live PASS 28,235 с (initial 1,4 с, Return→remote rollup 0,8 с).
Артефакты `/tmp/us4-joint27-review/`. Подробный итог и ограничения в последнем разделе; прежние
блокировки и FAIL ниже сохранены как история диагностики, они не являются текущим статусом.

Ветка `004-us4`, папка `/Volumes/YurySSD/Мои приложения/MyNotion-004-us4` (git worktree от `004-databases-core`). В неё уже влита
`004-us2` до `12982ce` (окна ячеек нужны окну связи) — при слиянии в основную ветку порядок US2 → US4 → US3 сохраняется сам.

## Сделано

- **Чтение связей — одно место**: `Databases/RelationLinks.swift`. Связи пары хранятся у свойства с меньшим id (`storage(of:)`),
  связанная строка видна, если она и её база не в корзине (база в корзине — в том числе со страницей-хозяином). Отсюда читают
  `RowWindow`, `FormulaInputs`, сводки, окно связи (`related`, `candidates`), настройка («Связана с»: `targetState`).
- **Операции** `Operations/DatabaseOperations+Relations.swift`: `addRelation` (с парой — `relatedName`), `setRelationLimit`,
  `setRelatedProperty(enabled:)` (выкл — пара в «Удалённые свойства», связи на месте; вкл снова — то же свойство), `linkRow`,
  `unlinkRow`, `createLinkedRow` («Создать «…»» — строка в базе-цели и связь одним шагом), `setRollup`. Лимит «1 страница» своей и
  ответной стороны снимает прежнюю связь той же правкой. Id новой пары всегда больше id связи — связи не переезжают.
- **Сводки** `Computation/Rollups.swift` (`RollupRecompute`): значения цели в виде для показа (варианты и текст — названиями,
  связь — `[{id, title}]`), `Calculations.compute`. `ComputationGraph` знает сводки (своя зависимость — связь, чужая — свойство
  цели), `ComputationHook` пересчитывает той же записью: сначала сводки, потом формулы, базы — по порядку чтения
  (`readingOrder`). Стёртые навсегда связи — `NotesChanges.database.erasedLinks` (только этому Mac). Корзина базы-цели — фоновый
  пересчёт читающих баз. Открытым видам других баз — `DatabaseOperations.announce` их пересчитанных строк.
  Очередь `FormulaRecomputeQueue`: сводки, потом формулы; `fillMissing` — и сводки.
- **Вид**: `PropertySettings/RelationSettings.swift` («Связана с», «Лимит ›», «Ответное свойство» с полем имени; общий
  `PropertyChoiceCard` — окно выбора сбоку), `RollupSettings.swift` («Связь ›», «Свойство ›», «Вычислить ›» разделами),
  `Cells/RelationCell.swift` (окно ячейки `RelationCellView` в `CellPopups.all`: поиск, «N выбрано» с «−», «Выбрать ещё»,
  «Создать «…»»), `Cells/RollupCell.swift`, `PropertyTypes/RollupType.swift` (проценты — «50%»). «+» → «Связь» / «Сводка» —
  сразу панель «Изменить свойство». Разделы связи и сводки перечитывают себя по `DatabaseOperations.didChange` (панель не
  пересобирается, пока фокус в имени).
- **Приложение**: `--relations-demo`, `--relations-demo-linked`, `--relations-demo-open <база>`; галерея — 9 состояний
  (`GalleryRelationsScene`); `scripts/imac/sync-live-check.sh --test <класс>`.

## Тесты

`RelationOperationsTests`, `RollupRecomputeTests` (имя `RollupTests` занято тестом типа), `RelationLinkMergeTests` (SyncTests
теперь зависит от `Databases`); UI — `RelationRollupTests`, два Mac — `SyncRelationsTwoMacsUITests`, замер —
`PerformanceTests/RelationRollupBudgetTests`. Итоги — quickstart.md, «US4».

## Спорные решения

- Связи, добавленные на двух Mac одновременно при лимите «1 страница», после встречи остаются обе (каждая — своя запись);
  следующая правка ячейки соблюдает лимит.
- Смена лимита не снимает прежние связи (следующая правка — по новому лимиту).
- Имя пары по умолчанию — название исходной базы (как Notion).
- «Вычислить» — один список с разделами, а не подменю «Количество ›», «Проценты ›», «Ещё ›» Notion.
- Окно связи постоянной высоты (по первому списку): иначе карточка пересоздавалась и забирала клавиши у поиска.
- Числовая сводка переиспользует NumberSettingsView US2: формат, точность, полоса/кольцо, цвет, делитель и показ числа. Настройки вложены в `numberFormat`; скалярный итог рисуется через общий NumberDisplay.meter.
- «Дублировать» базу со связями (spec, Edge Cases) не трогал — это копия ветки 003.


## Продолжение Codex, 22.10.2026 - передача координатору

Работа только в существующей `MyNotion-004-us4`, ветка `004-us4`. Основной checkout не изменялся,
`DatabaseGridView.swift` вручную не правился. Все сборки/тесты - iMac через
`imac-run --no-fallback --wait 1800`, максимум 4 потока; VM не использовалась.

### Коммиты

- `1d48e1b` - слияние общей ветки; фабрики US2 и RelationCellView сохранены вместе в CellPopups.all.
- `6a07c09` - безопасные iMac-скрипты, координатор внёс как `ca563af`: SecurityAgent и чужие MyNotion
  не завершаются; live очищает только PID собственного node, чужой занятый порт означает ошибку.
- `14df50d` - числовая панель сводки через NumberSettingsView/NumberDisplay US2, вложенный numberFormat,
  динамическая высота редактора, галерея rollup-number-settings, расширенные UI/live проверки.
- `28cd4b5` - aliveRows: PK lookup с `+parentId`, дедупликация, batch 500 id (501 bind), сохранение
  parent/trashed/template семантики. Correctness и EXPLAIN на настоящей схеме с 10 000 строками.
- `b488dd5` - PropertyMenuPresenter: overlay contentView, host.visibleRect∩host.bounds, координаты окна,
  scroll, resize/onResize, cleanup monitor/observers на close/removal/deinit. Реальная ошибка decimals
  была закрытием родительской панели при правильном click, а не неверным locator.
- `effe16d` - отдельный ComputedWriter conditional UPSERT: неизменный persisted JSON не переписывается,
  но sort/search/isLive восстанавливаются. NULL, массивы, числа, новые строки и уведомления проверены.
- `3d7e658` - scoped dependency fix Graph+Hook: indirect базы пересчитывают читателей связи и closure
  существующих FormulaRecompute/RollupRecompute. Direct базы и announce сохранены. Учтено неявное имя
  связанной страницы для format/join; graph инвалидируется после правки формулы/схемы.

### Подтверждено

- Все затронутые наборы после dependency fix: **73 теста / 10 наборов PASS, 7,379 с**.
  `/tmp/us4-dependent-fix-fetch/build/us4-dependent-fix/unit.log`.
  Проверены formula→formula, rollup→formula, цепочки между базами, rename/trash/restore/erase цели,
  schema/formula invalidation и сохранение независимого now при indirect правке.
- Дополнительно усилена title regression: штатный явный читатель Названия удалён, rename обязан
  заметить один format(связь). **19 тестов / 1 набор PASS, 2,924 с**.
  `/tmp/us4-ui-prebuild-fetch/build/us4-ui-prebuild/unit.log`. Production после принятого бюджета не менялся.
- Геометрия presenter и обычные свойства US2: **20/20, 3 набора PASS, 0,452 с**.
  `/tmp/us4-cold-profile3-fetch/build/us4-cold-profile-03/unit.log`.
- Приёмочный native Release cold-budget без sample/gate и диагностических env:
  **1 тест PASS, 3,724 с**, `/tmp/us4-dependent-fix-fetch/build/us4-dependent-fix/budget.log`, budget.exit=0.
  Эталон 10 000 задач / 500 проектов, крупный проект 1000 задач.
  Trash **73,4 / 44,7 / 59,9 / 40,4 / 43,3 мс**;
  restore **170,4 / 86,2 / 98,5 / 105,1 / 94,0 мс**, предел **200 мс** сохранён.
  p95 edit **3,4 мс**, relink **5,4 мс**, оба <=10 мс; **500/500** сводок совпали с прямым подсчётом.
  Измеряется transaction+ComputationHook, не отрисовка.

Ранние холодные нарушения сохранены в quickstart: исходный trash 359,2; после PK 260,8;
после UPSERT restore 210,266 мс. Профили не заменяют приёмку. Restore sample содержит всего 6 main отсчётов:
причина подтверждается также кодом и регрессиями, точная доля времени по нему не заявляется.
Профили и отдельные exit-коды: `/tmp/us4-cold-profile-fetch/`, `/tmp/us4-cold-profile3-fetch/`,
`/tmp/us4-restore-profile-fetch/`. Opt-in helper ColdTrashProfile пишет собственный PID/первый вызов;
паузы находятся вне измерения, обычный budget helper не активирует.

### Открытые живые проверки

**T089/T093/T094 остаются [ ].** Координатор ещё не получил unlock от Юрия. US3/hover сообщили
`CGSSessionScreenIsLocked=Yes`, loginwindow; нового собственного preflight US4 после этого нет.
До свежего unlock/preflight UI не запускать, системные окна не обходить и чужие процессы не завершать.

Первый свежий GUI-проход до блокировки:
- RelationRollupTests FAIL на decimals choice-2 после 70,556 с. Правильный click подтверждён снимками
  и Synthesized Event; presenter исправлен и прошёл unit, но живой повтор ещё не выполнен.
- Галерея остановилась на пропущенном `.rollupNumberSettings` в общем switch. Case добавлен,
  последующие Release-сборки прошли. Живые 9 состояний × 2 темы и сверка с Notion ещё открыты.
- Live **1 PASS, 32,997 с**: два экземпляра на одном iMac со своими SQLite/локальным сервером,
  не два физических Mac. Двустороннее добавление сохранило 5 связей и суммы 17/14; initial snapshot 1,6 с.
  Старые 0,0 с считали только ожидание после Return. Таймер перенесён перед Return с пределом 10 с;
  обновлённую версию live ещё повторить.

Артефакты первого GUI: `/tmp/us4-codex-review/{ui,live,perf}/`, desktop.png и windows.json.
Успешные live-снимки:
- `/tmp/us4-codex-review/live/attachments/relations-mac-a_0_F189C88C-1939-48BA-9F78-6D939671897C.png`
- `/tmp/us4-codex-review/live/attachments/relations-mac-b_0_88CED882-D405-4431-B18B-C65F6E58E427.png`

Debug build-for-testing завершён без запуска приложения, **build.exit=0**.
Журнал `/tmp/us4-ui-prebuild-fetch/build/us4-ui-prebuild/build.log`.
Собственная копия iMac: `/Users/ykurilov/.imac-runner/work/MyNotion-004-us4_-1c9044f6`.
Products: `build/imac-uitest-dd/Build/Products`, Debug/MyNotion.app. Не повторять идентичную сборку.
После unlock согласовать GUI с US3/hover, затем подготовленный `/tmp/us4-final-gui.sh` через
`scripts/imac/run-on-imac.sh lock -- "$(cat /tmp/us4-final-gui.sh)"`.
Сценарий делает desktop preflight, ждёт маркер `build/us4-final-review/run-ui` после осмотра,
переиспользует UI bundle для RelationRollupTests и Debug App для relation/rollup gallery, затем live.
Результаты UI/галереи/live и exit-коды раздельные. До осмотра preflight маркер не создавать.
После галереи визуально сверить 18 снимков с Notion, а не засчитать одно наличие файлов.

Координатору: интегрировать коммиты US4 в согласованном порядке US4→US3; открытые UI-задачи при интеграции
не отмечать выполненными. Подробные таблицы проверок и ограничений - quickstart.md, раздел US4.

## Возобновление на совместном коде

В `004-us4` fast-forward общей `4961489` выполнен без конфликтов, исходники сохранены.
Координатор сообщил unlock и порядок hover→US3→US4. Собственная обязательная incremental Debug
сборка остановилась **exit69 до компиляции**: выбранный Xcode требует принятия лицензии.
`/tmp/us4-joint-prebuild-fetch/build/us4-joint-prebuild/build.log`; build.exit отсутствует.
Выбран `/Users/ykurilov/Applications/Xcode.app/Contents/Developer`, версия 27.1; старый
`/Applications/Xcode.app` версии 16.4 не подходит проекту. Лицензия/выбор toolchain не менялись.
Координатор и US3 уведомлены. До ручного устранения блокировки новый bundle не готов; прежний
Debug bundle не является проверкой совместного source. GUI-слот не занят, fresh preflight не выполнялся.
Units 680 и принятый cold-budget не повторялись. Подготовленный `/tmp/us4-final-gui.sh` сохранён.

### Fail-fast сборок iMac

Исправлен `scripts/imac/lib.sh`: build_app сбрасывает APP до генерации и явно возвращает ошибку
xcodegen/xcodebuild, даже когда вызывается внутри if/|| и errexit не действует. Call sites gallery/run,
UI build-for-testing, live и query-profile явно прекращают выполнение до запуска старого App/bundle.
Memory helper прекращает выполнение до установки legacy cleanup trap при ошибке сборки; его существующий
широкий stop_all не использовался и требует отдельной правки перед будущим запуском memory-сценария.
Локальная разрешённая shell-проверка `zsh scripts/imac/tests/build-failure.zsh`: **15 PASS**,
без настоящих Xcode/Swift/app действий. Проверены generator42/build69, if/||/pipefail, сброс stale APP,
отсутствие запуска App/UI-test/cleanup при failure и успешное присваивание APP. `zsh -n` и diff-check PASS.
Реальные сборки по-прежнему заблокированы лицензией Xcode27.1, не повторялись.

## Joint27: toolchain разблокирован, bundle подготовлен

После сообщения координатора повторена только обязательная no-GUI Debug build-for-testing на совместных
исходниках common dc5235f/a7a298c (merge 57aba9b). **imac-run exit0, build.exit=0**,
Xcode 27.1 build 27A9275. Артефакты `/tmp/us4-joint27-prebuild-fetch/build/us4-joint27-prebuild/`:
`build.log`, `build.exit`, `toolchain.log`. Приложение не запускалось; units/cold-budget не повторялись.
Живая серия ожидает прямую передачу GUI от US3. Подготовленный `/tmp/us4-final-gui.sh` сохранён также
как `scripts/imac/us4-review.sh` для воспроизводимого прогона. Отдельный guard требует свежий
build.exit=0 до preflight и использования bundle; результаты идут в build/us4-joint27-review.

### Повторная блокировка после prebuild27

До передачи GUI от US3 hover сообщил GUI preflight exit78 при повторной блокировке.
Собственная read-only проверка US4 подтвердила `CGSSessionScreenIsLocked=Yes`,
`kCGSSessionSecureInputPID=650`, loginDone/onConsole=Yes.
`/tmp/us4-joint27-session-preflight.log`. Состояние сеанса не менялось, GUI US4 не ставился;
новых результатов RelationRollupTests/18 gallery/live нет. Bundle27.1 готов и сохранён.
T089/T093/T094 остаются открытыми; после нового unlock нужен свежий GUI preflight и передача от US3.

## Финальная адресная серия, 23.10.2026

После прямой передачи GUI от US3 выполнен fresh preflight и единая серия через
`scripts/imac/run-on-imac.sh lock -- 'bash scripts/imac/us4-review.sh'`. No-fallback, wait 1800, jobs 4.
Product source (`App/Packages/PerformanceTests/UITests`) совпадает с совместным 4eca0a2; product-правок
не потребовалось. Принятые 680 joint unit и cold-budget 73,4/170,4 мс не повторялись.

Guard первой попытки остановил выполнение до preflight из-за удалённого при rsync обычного build
(`/tmp/us4-joint27-gui-run.log`, exit3); App не запускался. Это ошибка подготовки кэша, не product failure.
Bundle восстановлен no-GUI в **.imac-runner-us4-build**, защищённом runner filter `P .imac-runner-*`;
`build` создаётся как ссылка. `/tmp/us4-protected27-prebuild-run.log`, process exit0/build.exit0,
логи `/tmp/us4-protected27-prebuild-fetch/`. Последующая GUI-синхронизация сохранила bundle.
Разрешённый `caffeinate -u -t 2` перед ioreg будит погасший дисплей, настройки блокировки не меняет.
Координатор выяснил, что прежний ScreenIsLocked-флаг относился к display sleep при screenLock=off.

| Этап | Фактический результат | Артефакт |
|---|---|---|
| Fresh desktop preflight | живой экран, без перекрывающих modal; фоновое DeepL update и уведомление Xcode не перекрыли тест | desktop.png/json, windows.json, session.txt |
| RelationRollupTests | **1 PASS, 65,886 с**, ui.exit0; relation/create row/undo/redo/sum/decimals2/edit hours | ui/uitest.log |
| Relation gallery | **6 состояний ×2 темы =12/12**, 26 с, gallery-relation.exit0 | gallery-relation/ |
| Rollup gallery | **3 состояния ×2 темы =6/6**, 13 с, gallery-rollup.exit0 | gallery-rollup/ |
| SyncRelationsTwoMacsUITests | **1 PASS, 28,235 с**, live.exit0; initial 1,4 с, Return→remote rollup **0,8 с <10 с** | live/uitest.log, live.log |

Корень всех артефактов `/tmp/us4-joint27-review/`; внешний runner
`/tmp/us4-joint27-gui2-run.log` exit0, отдельные ui/gallery-relation/gallery-rollup/live.exit все 0.
Live проверил 5 связей и суммы 17/14 в обеих базах после добавлений с обеих сторон; второй клиент открыл
таблицу «Проекты». Это два экземпляра на одном iMac с отдельными SQLite и локальным сервером, не два
физических Mac. Attachments обоих имён содержат снимки рабочего стола с тем же передним окном второго
клиента; визуально подтверждают открытую таблицу 17/14, равенство обеих SQLite подтверждают assertions.

Осмотрены все 18 PNG, сверены локальные notion-relation/rollup эталоны: новая/двусторонняя связь,
выбор базы и лимита, выбранные страницы с минусом/«Выбрать ещё», таблица с ответной связью и сводками,
настройки relation→property→calculate, формат/точность/полоса/кольцо/цвет/divideBy/showNumber.
Обе темы без перекрытия/выхода панелей за окно. Сохранён ранее документированный вариант: вычисления
одним прокручиваемым списком с разделами вместо вложенных Notion submenu; pixel-identical сравнение
не заявляется. T093 закрыта по фактической генерации и визуальному осмотру 18 снимков.

Актуальные снимки:
- `/tmp/us4-joint27-review/gallery-rollup/rollup-number-settings--1440x900--dark.png`
- `/tmp/us4-joint27-review/gallery-relation/relation-picker--1440x900--light.png`
- `/tmp/us4-joint27-review/live/attachments/relations-mac-a_0_67BF2735-5D89-46CF-9182-CCC4447E5B26.png`
- `/tmp/us4-joint27-review/live/attachments/relations-mac-b_0_8033D41C-45E2-475B-A7A5-9430D3235482.png`

**T089/T093/T094 отмечены [x] только после PASS.** GUI-слот освобождён, координатор и US3 уведомлены.
Основной checkout не правился; интеграцию финального harness/docs/tasks коммита выполняет координатор.
