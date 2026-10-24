# Контракт: каталог команд

Вызов: `mynotion <группа> <действие> [аргументы] [флаги]`. Имя в протоколе — `группа.действие`.
Обозначения: `<стр>` — указатель страницы (id, путь из названий, `current`); `<блок>` — id блока; `<база>` — указатель страницы базы; `<свойство>`, `<вид>`, `<вариант>` — имя или id. **R** — чтение, **W** — запись, **B** — можно в `batch`.

Весь каталог закрепляется на этапе 1. Обработчики групп пишутся на этапах 2–7; до этого — `not_implemented`.

## Служебные (этап 1)

| Команда | Аргументы и флаги | Тип |
|---------|-------------------|-----|
| `app status` | — | R: версия, протокол, путь базы, окна, идёт ли импорт |
| `commands` | `--json` | R (без приложения) |
| `batch` | `--file <json>` или stdin: `[{"command":"page.create","args":{…}}, …]`; `"$N.путь"` — значение из ответа шага N | W |
| `sync status` / `sync now` | — | R / W |

## Страницы — `page` (этап 2, US1)

| Команда | Аргументы и флаги | Тип |
|---------|-------------------|-----|
| `page tree` | `[<стр>] [--depth N]` | R |
| `page get` | `<стр>`: id, название, иконка, обложка, путь, родитель, дети, тип (page/database/row), широкая, мелкий шрифт, в избранном, шаблон, даты | R |
| `page read` | `<стр> [--format markdown\|json] [--with-children]` | R |
| `page create` | `[--parent <стр>] --title T [--icon 🚀] [--after <стр>] [--template <стр>] [--markdown <файл\|->]` | W B |
| `page write` | `<стр> --markdown <файл\|->` (замена содержимого) | W B |
| `page append` | `<стр> --markdown <файл\|-> [--after <блок>]` | W B |
| `page rename` | `<стр> --title T` | W B |
| `page move` | `<стр> --parent <стр>\|--root [--after <стр>\|--first]` | W B |
| `page duplicate` | `<стр>` | W |
| `page trash` / `page restore` | `<стр>` | W B |
| `page layout` | `<стр> [--full-width on\|off] [--small-text on\|off]` | W B |
| `trash list` | — | R |
| `trash delete` | `<стр> --force` (навсегда) | W |
| `trash empty` | `--force` | W |

## Блоки, иконки, обложки — `block`, `page icon`, `page cover` (этап 3, US2)

| Команда | Аргументы и флаги | Тип |
|---------|-------------------|-----|
| `block kinds` | — | R: список видов и их свойств (block-json.md) |
| `block get` | `<блок>` | R |
| `block insert` | `<стр> --kind K [--text "Markdown строки"] [--props JSON] [--after <блок>\|--first\|--last\|--inside <блок>]` | W B |
| `block update` | `<блок> [--text …] [--props JSON] [--kind K]` (смена вида — как «Превратить в») | W B |
| `block move` | `<блок> --after <блок>\|--first\|--last` (с вложенными) | W B |
| `block indent` / `block outdent` | `<блок>` | W B |
| `block check` / `block uncheck` | `<блок>` | W B |
| `block expand` / `block collapse` | `<блок>` (раскрывающийся список, заголовок-раскрытие) | W B |
| `block delete` | `<блок>` | W B |
| `block move-to-page` | `<блок> --page <стр>` (как «Переместить в…») | W B |
| `page icon` | `<стр> --emoji 🚀\|--remove` | W B |
| `page cover` | `<стр> --gallery <имя>\|--file <путь>\|--remove [--offset 0…1]` ; `page cover --list` — галерея | W B |

## Базы — `db` (этап 4, US3)

| Команда | Аргументы и флаги | Тип |
|---------|-------------------|-----|
| `db create` | `--parent <стр> --title T [--inline [--after <блок>]]` | W B |
| `db schema` | `<база>` — свойства, варианты, виды | R |
| `db prop add` | `<база> --name N --type T [--config JSON] [--after <свойство>]` | W B |
| `db prop update` | `<база> <свойство> [--name N] [--config JSON]` (формат числа, лимит связи, сводка, формула `--formula "…"`, дата) | W B |
| `db prop type` | `<база> <свойство> --type T` (перевод значений по 004) | W B |
| `db prop move` / `db prop duplicate` / `db prop delete` / `db prop restore` | `<база> <свойство> [--after …]` | W B |
| `db option add` / `rename` / `color` / `move` / `delete` | `<база> <свойство> <вариант> [--name] [--color] [--group todo\|inProgress\|complete] [--after]` | W B |
| `db row add` | `<база> --values JSON` или `--rows <файл\|->` (массив, до 1 000) `[--template <шаблон>]` | W B |
| `db row update` | `<база> <строка> --values JSON` | W B |
| `db row trash` / `db row restore` / `db row duplicate` | `<база> <строка>…` | W B |
| `db cell set` | `<база> <строка> <свойство> --value JSON` | W B |
| `db relation link` / `unlink` | `<база> <строка> <свойство> --to <строка>…` | W B |
| `db rows` | `<база> [--view <вид>] [--filter JSON] [--sort JSON] [--search T] [--properties a,b] [--limit] [--cursor]` | R |
| `db view list` | `<база>` | R |
| `db view add` / `rename` / `duplicate` / `delete` / `move` | `<база> [<вид>] [--name]` | W B |
| `db view update` | `<база> <вид> [--filter JSON] [--sort JSON] [--group JSON] [--visible a,b] [--hidden a,b] [--order a,b] [--width имя=пикс] [--wrap on\|off] [--calc имя=функция] [--open-in side\|center\|full] [--load-limit N] [--group-hide ключ] [--group-show ключ] [--group-collapse ключ] [--group-expand ключ] [--group-order k1,k2] [--order-rows <строка> --after <строка>]` | W B |
| `db template list` / `add` / `default` / `delete` | `<база> [<шаблон>]` — когда шаблоны строк 004 (US6) влиты | W B |
| `db export` | `<база> --to <папка>` (CSV + Markdown + схема 004) | R |

Значения ячеек, фильтр, сортировка, группировка — contracts/block-json.md, разделы «Ячейки» и «Вид».

## Поиск, избранное, недавние, шаблоны, история, вложения (этап 5, US4)

| Команда | Аргументы и флаги | Тип |
|---------|-------------------|-----|
| `search` | `"слова" [--limit]`: id, название, путь, отрывок, тип | R |
| `favorites list` / `add` / `remove` / `move` | `[<стр>] [--index N]` | R / W B |
| `recents` | `[--limit]` | R |
| `template list` / `mark` / `unmark` | `[<стр>]` | R / W B |
| `history list` | `<стр>`: id версии, время, Mac, сводка, `agent` | R |
| `history show` | `<стр> <версия> [--format markdown\|json]` | R |
| `history restore` | `<стр> <версия>` (с версией до восстановления) | W |
| `attachment add` | `<стр> --file <путь> [--after <блок>] [--as image\|file\|video]` или `<база> <строка> <свойство> --file …` | W B |
| `attachment list` | `<стр>` | R |
| `attachment get` | `<id вложения> --to <путь>` | R |

## Окно (этап 6, US5)

| Команда | Аргументы и флаги | Тип |
|---------|-------------------|-----|
| `window state` | окна, вкладки, страница каждой, переднее окно | R |
| `open` | `<стр> [--new-tab\|--new-window] [--block <блок>] [--activate]` | W |
| `tab new` / `select` / `close` / `reopen` | `[--window N] [--tab N]` | W |
| `nav back` / `nav forward` | `[--window N]` | W |

## Импорт и выгрузка (этап 7, US6)

| Команда | Аргументы и флаги | Тип |
|---------|-------------------|-----|
| `import notion` | `<архив .zip или папка> [--parent <стр>]`; ход — строками `progress`, итог — отчёт импорта | W |
| `export page` | `<стр> --to <папка> [--no-children]` | R |
| `export all` | `--to <папка>` | R |
