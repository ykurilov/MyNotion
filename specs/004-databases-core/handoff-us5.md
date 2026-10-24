# Передача: US5 «Формулы» (волна B, T046–T056)

Ветка `004-us5`, папка `/Volumes/YurySSD/Мои приложения/MyNotion-004-us5` (git worktree от `004-databases-core`).

## Что сделано

- **Язык** — `PK/Sources/Formulas/`: дерево с местом каждого узла (`Expression`), разбор с ошибками по-русски (`Parser`, `Lexer`),
  проверка типов и круга (`FormulaTypes`: `FormulaTypeChecker`, `FormulaSchema`), вычисление (`Evaluator`), функции по разделам
  (`Functions/{Logic,Numbers,Text,Dates,Lists,Pages}.swift`, общие разборы — `Signatures.swift`), каталог с описаниями и примерами
  (`FunctionCatalog`), подсветка (`FormulaHighlight`), названия свойств ↔ id (`FormulaSource`).
- **Хранение**: в `config.expression` — `prop("<id>")`; Юрий видит и пишет названия. Переименование свойства формул не трогает.
  `config.resultType` — тип итога (`number`, `text`, `checkbox`, `date`, `list`, `page`, `unknown`).
- **Пересчёт** — `PK/Sources/Databases/Computation/`: `ComputationHook` (подписчик записи: своя строка и связанные — в той же
  транзакции, базы по порядку цепочки), `ComputationGraph` (что от чего зависит), `FormulaRecomputeQueue` (полный пересчёт в фоне
  по R21, склейка запросов, `fillMissing` — первое заполнение), `LiveFormulaClock` («живые» раз в минуту у открытых видов),
  `FormulaPreview`, `DatabaseFormulaSchema`, `DatabaseOperations+Formula.swift` (`setFormula` — проверка, запись, ⌘Z).
  `FormulaRecompute`: формулы по порядку зависимостей, итог формулы сразу виден зависящим.
- **Вид**: `DatabaseGrid/PropertySettings/FormulaEditor/` — `FormulaEditorModel` (проверяется тестами), `FormulaEditorView`
  (окно как у Notion), `FormulaField` (плашки свойств — вложения в тексте), `FormulaEditorPresenter` (карточка рядом с панелью).
  `Cells/FormulaCell.swift`; показ итога — `CellPresenter` / `ComputedType` (список страниц — плашками с названиями).
- **Приложение**: `App/MainWindow/FormulasAddon.swift` (подписчик, очередь, часы; уведомление `.formulasDidRecompute`),
  `App/Launch/FormulaEditorDemo.swift` (`--formula-editor-demo` для UI-сценария), галерея — `GalleryFormulasScene.swift`.

## Что сделать при вливании (стыки с US1)

1. `GridCellTypes.all` (US1, `Cells/GridCellType.swift`): добавить `FormulaCell()` и `extension FormulaCell: GridCellType {}` —
   у `FormulaCell` уже есть `kind` и `editingText`.
2. Панель «Изменить свойство» (US1): у формулы пункт «Изменить формулу» → `FormulaEditorPresenter().show(property:rows:operations:besides:)`.
3. Открытый вид базы (US1, `DatabasePageHost`): `FormulasAddon.viewOpened(databaseId)` / `viewClosed(databaseId)`;
   по `.formulasDidRecompute` (object — id базы) — перечитать видимые строки.
4. Фильтр по формуле по типу итога (US3): `config.resultType` — какие условия показывать.
5. `GalleryCatalog.databaseStates` и `GalleryDatabases` — у US1 и US5 свои строки в конце; конфликт — сложить оба набора.

## Спорные решения

- Длина и номера в тексте — по символам Swift (у Notion — UTF-16 JavaScript): у эмодзи `length("😀")` = 1, у Notion 2.
- Сверка семантики — по справке Notion «Formula syntax» (notion.com/help/formula-syntax): все её примеры вошли в каталог
  как есть и проходят тест. Найдено и поправлено: `day()` у Notion — 1 понедельник … 7 воскресенье (в contracts было
  «0 — воскресенье», contracts поправлены); `format(дата)` — `October 21, 2026 17:56` (24 часа, английский), `formatDate` — на
  языке macOS. Живой Notion в ВМ не открывался: в этом окружении нет консольной команды `cua` для щелчков в ВМ.
- `empty(false)` = true (как пустой флажок в фильтре).
- `if` с ветками разных типов — тип «неизвестно», не ошибка.
- Порядок разделов списка — как у Notion (Общие, Текст, Числа, Даты, Списки), в contracts — по смыслу.
- Без строки ИИ «Write, fix, or explain…» и «Debug mode» Notion: в contracts их нет.

## Остановка при первом заполнении (закрыто)

Причина — мусор генерации эталона в подготовке теста, который главный поток освобождал во время замера (стек:
`objc_autoreleasePoolPop ← -[_NSCallStackArray dealloc]`). Подготовка — в своём пуле; проба на основном Mac — главный поток
≤ 6 мс. Подробно — quickstart.md, «US5». Повтор `FormulaBudgetTests` в ВМ — когда её включат.
