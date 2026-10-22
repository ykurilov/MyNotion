# Передача: US4 «Связи и сводки» (волна C, T086–T094)

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


## Продолжение Codex (22.10.2026)

- Влита интеграционная ветка (`1d48e1b`); US2 и RelationCellView остаются вместе в CellPopups.all, добавлена регрессия реестра.
- `6a07c09`: безопасные iMac-скрипты, без убийства SecurityAgent и чужих MyNotion; координатор внёс как `ca563af`.
- Числовые настройки сводки реализованы через NumberSettingsView (вложенный configKey), без дублирования панели или форматтера US2.
  У RollupSettingsView динамическая высота; добавлена галерея rollup-number-settings в обеих темах (всего 9 состояний US4).
- Unit на iMac после всех этих правок: 57/57, 8 наборов, `/tmp/us4-codex-unit2.log`. Начальный прогон после слияния - 37/37,
  `/tmp/us4-codex-unit.log`. Все - no-fallback, 4 потока. DatabaseGridView.swift вручную не менялся.
- UI-сценарий дополнен выбором точности сводки. Live-сценарий заменяет число через ⌘A (иначе редактор дописывал к прежнему),
  открывает «Проекты» второго клиента и проверяет добавление связей с обеих сторон вместе со сводками 17/14.
- Старый `/tmp/us4-uitest8` провален; hierarchy показывает перекрывающие CoreServicesUIAgent предупреждения ChatGPT.
  Старый `/tmp/us4-perf.log` - замер другой задачи 003. Устаревшее ожидающее UI с PID65048 отменено до запуска по указанию
  координатора (exit130), а не зачтено как проверка. Свежие GUI-итоги фиксируются в quickstart.md.
