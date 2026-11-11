# Страницы и корзина

Ответы ниже сокращены: `…` — опущенные поля. Страница в ответе всегда одна и та же:
`id`, `title`, `icon`, `kind` (`page`, `database` или `row` — строка базы), `parentId`, `path`, `hasChildren`, `cover`,
`fullWidth`, `smallText`, `isFavorite`, `isTemplate`, `inTrash`, `createdAt`, `updatedAt`.

## Найти и прочитать

```bash
mynotion page tree --depth 1                 # корень и один уровень детей; без --depth — всё дерево
mynotion page tree Проекты                   # ветка от страницы
mynotion page get "Проекты/Встреча 24.10"    # свойства, путь, тип
mynotion page read "Проекты/Встреча 24.10"   # содержимое в Markdown
mynotion page read "Проекты/Встреча 24.10" --format json   # блоки с id: их берут команды block …
mynotion page read Проекты --with-children   # и подстраницы, каждая своим Markdown
```

```json
{"ok":true,"data":{"items":[{"id":"…","title":"Проекты","kind":"page","path":["Проекты"],"hasChildren":true,
  "children":[{"id":"…","title":"Встреча 24.10","path":["Проекты","Встреча 24.10"],"hasChildren":false,…}],…}],"nextCursor":null}}
{"ok":true,"data":{"page":{"id":"…","title":"Встреча 24.10",…},"markdown":"# Повестка\n\n…"}}
```

- На последнем уровне `--depth` поля `children` у страницы нет, даже если `hasChildren: true`. Детей этой страницы даёт большая глубина или `page tree <страница>`.
- В дереве нет корзины и шаблонов строк баз. Строки баз видны как `kind: "row"` под своей базой.
- Подстраница в Markdown — строка `[Название](mynotion://page/<id>)`. Упоминание внутри текста — такая же ссылка.
- Файлы в Markdown — полным путём их копии в папке вложений приложения.

## Создать с Markdown

```bash
mynotion page create --parent Проекты --title "Встреча 24.10" --icon 🚀 --markdown notes.md
cat notes.md | mynotion page create --title Черновик --markdown -       # в корне, текст из stdin
mynotion page create --parent Проекты --title Итоги --after "Проекты/Встреча 24.10"
mynotion page create --parent Проекты --title "Отчёт" --template "Шаблон отчёта"
```

```json
{"ok":true,"data":{"page":{"id":"…","title":"Встреча 24.10","icon":"🚀","parentId":"…","path":["Проекты","Встреча 24.10"],…}}}
```

- Понимает: заголовки, списки с вложенностью, задачи `- [ ]`, код с языком, цитаты, таблицы, формулы `$$`, разделитель,
  `<aside>` (выноска), `<details>` (раскрывающийся список), ссылки на страницы.
- Ширины столбцов таблицы задаёт пометка `<!-- mynotion:table widths="…" -->` строкой перед таблицей. Без неё новая таблица делится поровну на всю ширину текста.
- Пустая строка между списком и следующим абзацем или задачей при обратном чтении `page read` пропадает: Markdown после записи может выглядеть чуть плотнее, смысл тот же.
- Строка `- [ ] текст` становится блоком-задачей (чекбоксом), `- [x]` — отмеченной.
- Блок, который понадобится правке, берут из `page read <страница> --format json`: `data.blocks[]` с `id`, `kind`, `text`, `checked`, `indent`. Этот `id` — для `block check`, `block update` и других команд `block …`.
- Первый заголовок — часть текста, а не название: название задаёт `--title`.
- Картинка или файл по пути (от папки, где запущена команда) копируется во вложения.
- Чего в MyNotion нет, переносится текстом, а в ответе `warnings` с кодом `markdown_unsupported` и номером строки:
  HTML, сноски, картинка по ссылке из интернета (становится закладкой), файл, которого нет.
- `--template` — как «по шаблону» в окне: копия шаблона с его подстраницами, название — из `--title`.

## Заменить и дописать

```bash
mynotion page write "Проекты/Встреча 24.10" --markdown notes.md            # всё содержимое заново
echo '- [ ] позвонить' | mynotion page append "Проекты/Встреча 24.10" --markdown -
mynotion page append "Проекты/Встреча 24.10" --markdown - --after <id блока> < more.md
```

- `write` не удаляет подстраниц: ссылки на них, которых нет в новом Markdown, остаются в конце страницы.
- Открытая в окне страница меняется сразу, недописанный человеком текст в ней не теряется.

## Переложить, переименовать, вид

```bash
mynotion page rename "Проекты/Встреча 24.10" --title "Встреча 24.10 — итоги"
mynotion page move "Встреча 24.10 — итоги" --parent Архив --first      # или --after <соседняя>
mynotion page move "Архив/Встреча 24.10 — итоги" --root
mynotion page duplicate "Шаблон недели"                                # копия с подстраницами
mynotion page layout "Архив/Встреча 24.10 — итоги" --full-width on --small-text off
```

- Внутрь себя или своей подстраницы — ошибка `cannot_move`.

## Ссылка для чтения

```bash
mynotion page share on "Проекты/Отчёт"                 # {"enabled":true,"url":"https://…/s/…","includeSubpages":true,"published":true}
mynotion page share on "Проекты/Отчёт" --subpages off  # только сама страница и её встроенные базы
mynotion page share show "Проекты/Отчёт"               # ссылка как есть, ничего не меняет
mynotion page share off "Проекты/Отчёт"                # ссылка сразу перестаёт открываться
mynotion page share rotate "Проекты/Отчёт"             # новая ссылка, старая сразу не работает
```

- Ссылку откроет любой, у кого она есть, без входа. Включать и менять — только по просьбе Юрия.
- Выключили и снова включили — ссылка та же. Нужна другая — `rotate`.
- Правки страницы попадают на сайт сами, через несколько секунд.
- Работает через сервер синхронизации. Она выключена — ошибка `sync_disabled`.

## Корзина

```bash
mynotion page trash Черновик                 # {"id":"…","inTrash":true}
mynotion trash list                          # что лежит в корзине
mynotion page restore Черновик               # вернуть на прежнее место
mynotion trash delete Черновик --force       # навсегда, только по прямой просьбе Юрия
mynotion trash empty --force                 # очистить корзину навсегда
```

- Без `--force` удаление отвечает `force_required` и ничего не трогает.
- `restore` и `trash delete` ищут страницу и в корзине: `--include-trashed` им не нужен.

## Откатить правку агента

- Перед первой правкой страницы приложение само сохраняет версию «до правки агента (имя)».
- Вернуть всё, что сделал агент: в окне «История версий» страницы → эта версия → «Восстановить».
- Команды истории (`history list`, `history restore`) — [library.md](library.md).
