# Передача: US2 «Типы» (T065–T075)

Ветка `004-us2`, папка `/Volumes/YurySSD/Мои приложения/MyNotion-004-us2` (git worktree от `004-databases-core`). Все сборки и тесты — на iMac.

## Сделано

- Операции: `Databases/Operations/DatabaseOperations+Options.swift` (создать из ячейки со случайным цветом не как у предыдущего,
  выбрать / снять, Enter — найти или создать и выбрать одним шагом, переименовать, цвет, удалить из всех строк с ⌘Z, перетащить —
  и между группами статуса, сортировка списка `config.optionSort`; повторы имён с двух Mac — первый по id, значение переводится на
  него при правке), `+Files.swift` (добавить файлы и ссылки, убрать). Новый статус — три группы и «Не начато» / «В работе» / «Готово»
  (`addProperty`).
- Модели без вида: `PropertyTypes/DateCellValue.swift` (диапазон, время, ввод текстом, напоминания, календарь с понедельника),
  `FilesValue.swift`, `NumberDisplay.swift` (форматы Notion, знаки, «Показывать как»). `CellPresentation`: `.meter`, у плашки —
  точка статуса и миниатюра картинки.
- Окна ячеек — реестр `DatabaseGrid/Cells/CellPopup.swift` (US4 подключает окно связи туда же), крючок сетки
  `DatabaseGridView+CellPopup.swift`: `SelectCell.swift` (выбор, множественный, статус), `OptionListView.swift` (ручки, меню «⋯» с цветами),
  `DateCell.swift`, `FilesCell.swift`, `CellChipStyles.swift`, `NumberMeterDrawing.swift`.
- Настройки в «Изменить свойство»: `PropertySettings/{TypeSettingsView,SelectSettings,NumberSettings}.swift` (дата — в `TypeSettingsView.swift`).
- Напоминания ячеек: текст уведомления «Свойство: дата» (`ReminderIndex.cellContent`), щелчок — строка на всю страницу
  (`PagesLibrary.openBlock`), первое «Напомнить» — разрешение macOS (`DateReminderPermission`).
- `CellIndexer`: один новый вариант сдвигает место только у ячеек после него (замер Enter: p95 762 → 2 мс).
- Галерея: `App/Launch/UIGallery/GalleryTypesScene.swift`, 11 состояний `type-*`. UI-сценарий `UITests/SelectStatusDateTests.swift`.

## Проверки (iMac)

- `swift test --filter "DatabasesTests|DatabaseGridTests|RemindersTests|DatabaseRowPageTests|UIGalleryTests|AttachmentsTests"` — 267 зелёные.
- `SelectStatusDateTests` — зелёный. Галерея `--only type-` — 26 снимков. Замер — quickstart.md, «US2».

## Не сделано / спорное

- Статус у новой строки по умолчанию «Не начато» (как Notion) — это `NewRowDefaults` (файл US3), не трогал.
- Пункт «Изменить свойство» внизу окна статуса и «Notifications» в настройках даты — не сделаны.
- Перетаскивание файла из Finder — на окно файлов (не на саму ячейку сетки: `GridDocumentView` — файл US1/US3).
- «Включить время» ставит 9:00 (у Notion — текущее время); новый вариант из ячейки статуса — в «К выполнению».
- Живой Notion не сверялся (недоступен) — только снимки `visual-reference/`.
- Ловушка UI-тестов на iMac: окно приложения узкое — сценарий сужает новые колонки до 110; поверх окна может висеть чужой Терминал.
