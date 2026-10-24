# Импорт, выгрузка, синхронизация

Перенести заметки из Notion, сохранить страницы в Markdown-файлы, узнать, синхронизирован ли этот Mac.
Результат тот же, что у меню приложения. Перед импортом и выгрузкой открытые правки сохраняются.

## Импорт из Notion

```bash
mynotion import notion ~/Downloads/Export.zip --agent Codex            # архив .zip (вложенные ZIP тоже) или папка
mynotion import notion ~/Downloads/Export.zip --parent Проекты         # ветка импорта — внутрь «Проекты»
mynotion --human import notion ~/Downloads/Export.zip                  # ход строками в stderr: «… 12 из 340 — writing»
```

- Без `--parent` ветка ложится в корень, как у импорта из меню. Ответ: `{report:{rootPageId, rootTitle, pageCount, blockCount, …}, page:{…}, previousImport}`.
- Ход идёт строками `progress`: сначала `reading`, потом `writing`. Долгий импорт не мешает чтению: `page read`, `search` отвечают сразу.
- Связь с клиентом оборвалась — импорт всё равно доходит до конца. Проверить: `mynotion app status` (`importing`).
- Та же выгрузка уже импортировалась — команда импортирует ещё раз и пишет прошлый раз в `previousImport`. Не нужен дубль — проверяйте его заранее.
- В окне идёт импорт из меню — `window_busy`. Нет файла — `file_not_found`. Не выгрузка Notion — `invalid_value`.
- Юрий остановил импорт в окне — `write_failed`, ветка убирается целиком.

## Выгрузка в Markdown

```bash
mynotion export page Проекты/Встреча --to ~/Desktop                 # страница с подстраницами
mynotion export page Проекты/Встреча --to ~/Desktop --no-children   # одна страница
mynotion export all --to ~/Desktop                                   # вся библиотека, как «Выгрузить всё» в меню
mynotion db export Проекты/Задачи --to ~/Desktop                     # база: Задачи.csv, схема и строки файлами
```

- Каждая выгрузка — новая папка внутри `--to`: `<Название>-выгрузка-<дата>`. Ответ: `{folder, pageCount, blockCount, missingFiles}`.
- Папки `--to` нет — `file_not_found` (с подсказкой `mkdir -p`). Относительный путь считается от текущей папки.
- Файлы вложений, которых нет на диске, выгрузка пропускает и пишет `notice`.

## Синхронизация

```bash
mynotion sync status   # {enabled, status: off|ready|sending|error, detail, lastSyncedAt, deviceName}
mynotion sync now      # синхронизировать сейчас и дождаться итога
```

- Включить синхронизацию и войти можно только в окне: Настройки MyNotion → Синхронизация. Команды этого не делают.
- Выключена — `sync now` отвечает `sync_disabled` (код 4).
- Эти команды не входят в `batch`: `not_batchable`.
