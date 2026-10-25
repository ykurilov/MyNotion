# Поиск, избранное, недавние, шаблоны, история, вложения

Ответы ниже сокращены: `…` — опущенные поля. Страница в ответе — та же, что в `pages.md`.

## Найти по слову

```bash
mynotion search "Встреча"              # как ⌘P: сначала совпадения в названии, потом в тексте; 20 страниц
mynotion search "план запуска" --limit 5
```

```json
{"ok":true,"data":{"items":[{"id":"…","title":"Встреча 24.10","icon":null,"kind":"page","path":["Проекты","Встреча 24.10"],
  "snippet":null,"blockId":null},{"id":"…","title":"Итоги","path":["Итоги"],"snippet":"…обсудили на встрече план…","blockId":"…"}],"nextCursor":null}}
```

- Все слова должны быть в названии или в одном блоке. Корзины в выдаче нет.
- `blockId` — блок, где нашлось слово (если не в названии): `mynotion open <стр> --block <blockId>`.
- Строки баз ищет `mynotion db rows <база> --search "слово"`.

## Избранное и недавние

```bash
mynotion favorites add "Проекты/Встреча 24.10"
mynotion favorites list
mynotion favorites move "Проекты/Встреча 24.10" --index 0     # первой
mynotion favorites remove "Проекты/Встреча 24.10"
mynotion recents --limit 10                                    # недавние, свежая сверху; поле visitedAt
```

- Боковая панель меняется сразу. Повторное `add` и `remove` ничего не меняют.
- `move` страницы не из избранного — `invalid_value`.
- Недавние — открытые в окне страницы. Шаблонов и корзины в них нет.

## Создать из шаблона

```bash
mynotion template mark "Шаблон встречи"      # как «Сделать шаблоном»: страница уходит в корень
mynotion template list
mynotion page create --parent Проекты --title "Встреча 31.10" --template "Шаблон встречи"
mynotion template unmark "Шаблон встречи"
```

- Новая страница — копия шаблона с подстраницами; «@сегодня» шаблона становится днём создания.
- Шаблоны строк баз — `mynotion db template …`. Строку базы `template mark` не отмечает.

## Вернуть версию «до правки агента»

Перед первой правкой страницы (раз в 10 минут) приложение само сохраняет версию «до правки агента (<имя>)».

```bash
mynotion history list "Проекты/Встреча 24.10"
mynotion history show "Проекты/Встреча 24.10" <id версии>                 # Markdown версии
mynotion history show "Проекты/Встреча 24.10" <id версии> --format json   # блоки
mynotion history restore "Проекты/Встреча 24.10" <id версии>
```

```json
{"ok":true,"data":{"items":[{"id":"…","createdAt":"2026-10-25T09:12:03Z","device":"iMac","summary":"изменено 2 блока","agent":null,…},
  {"id":"…","createdAt":"2026-10-25T09:10:41Z","summary":"до правки агента (Codex)","agent":"Codex",…}],"nextCursor":null}}
{"ok":true,"data":{"page":{…},"restoredVersion":{"id":"…","agent":"Codex",…}}}
```

- Первая строка `list` — текущий вид страницы. Версию «до правки агента» ищите по полю `agent`.
- `<id версии>` — целиком или первые 8 знаков, если они не повторяются.
- `restore` сам сохраняет текущий вид версией: вернуть обратно — `restore` той версии. В `batch` его нельзя (`not_batchable`).

## Приложить файл и достать вложение

```bash
mynotion attachment add "Проекты/Встреча 24.10" --file ~/Desktop/отчёт.pdf             # блок-файл в конце
mynotion attachment add "Проекты/Встреча 24.10" --file схема.png --after <id блока>    # картинка за блоком
mynotion attachment add "Проекты/Встреча 24.10" --file ролик.mp4                       # видео
mynotion attachment add "Проекты/Встреча 24.10" --file схема.png --as file             # картинку — файлом
mynotion attachment add Задачи "Отчёт" Файлы --file отчёт.pdf                          # в ячейку «Файлы» строки
mynotion attachment list "Проекты/Встреча 24.10"
mynotion attachment get <id вложения> --to ~/Downloads             # в папку под своим именем
mynotion attachment get <id вложения> --to ~/Downloads/копия.pdf   # или под другим
```

```json
{"ok":true,"data":{"block":{"id":"…","kind":"image",…},"attachment":{"id":"…","name":"схема.png","byteCount":48213,
  "contentType":"public.png","path":"/Users/…/Attachments/…/схема.png"},"page":{…}}}
{"ok":true,"data":{"path":"/Users/…/Downloads/схема.png","attachment":{…}}}
```

- Вид блока — по типу файла, как при перетаскивании из Finder: картинка, видео или файл. `--as` задаёт вид сам.
- Пустой абзац, за которым кладётся файл, становится этим файлом.
- Путь — от папки, где запущена команда, или полный. Файла нет — `file_not_found`. Больше 100 МБ — `invalid_value`.
- `list` — обложка (`kind: "cover"`), затем файлы блоков по порядку; `path: null` — файл ещё скачивается с другого Mac.
