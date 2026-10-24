# Блоки, иконки, обложки

Блок — только по id. Id приходят в ответе `block insert` и в `mynotion page read <стр> --format json`. Страница в командах блоков — `current`, id или путь (как везде).
Все примеры ниже выполнены на Release-сборке; ответы сокращены (`…`) до нужного.

## Прочитать

```bash
mynotion block kinds                 # все виды и их свойства: data.kinds[] {kind, summary, props, hasText, canHaveChildren}
mynotion block get 01a16fb5-ce3b-7485-bcb6-0c53cff49c92
```

Ответ `block get` (то же лежит в `data.block` любой команды блока):

```json
{"ok":true,"data":{"pageId":"01a16fb5-b6ff-…","block":{"id":"01a16fb5-ce3b-…","kind":"checkbox","text":"Купить **молоко**",
 "rich":{"string":"Купить молоко","runs":[{"from":7,"to":13,"style":"bold"}]},"indent":0,"checked":false,
 "color":{"text":null,"background":null},"props":{},"linkedPageId":null}}}
```

Что окно ещё не записало, команда сначала сохраняет на диск: читается то, что видит Юрий.

## Вставить

Место — одно из `--first`, `--last`, `--after <блок>`, `--inside <контейнер>`; без места блок встаёт в конец.

```bash
mynotion block insert current --kind paragraph --text 'Заметки к встрече' --first
mynotion block insert current --kind checkbox --text 'Купить **молоко**' --after 01a16fb5-cda2-…
mynotion block insert current --kind callout --text 'Итог' --props '{"icon":"💡"}' --after 01a16fb5-ced1-…
mynotion block insert current --kind numberedItem --rich '{"string":"Важно","runs":[{"from":0,"to":5,"style":"bold"}]}' --after …
mynotion block insert current --kind paragraph --text 'Внутри списка' --inside <id раскрывающегося списка>
```

- Текст — `--text` (Markdown строки: `**жирный**`, `*курсив*`, `` `код` ``, `[ссылка](url)`) или `--rich` (точная разметка: `bold italic strikethrough code underline link:<url> textColor:<цвет> backgroundColor:<цвет> mention:<id> date:<ISO> equation`). Вместе — нельзя.
- `code` и `equation`: текст как есть, без Markdown.
- Таблица: `--kind table --props '{"rows":[["Имя","Роль"],["Аня","Автор"]],"hasHeaderRow":true}'`. Колонки: `--kind columnList --props '{"columns":2}'` (от 2). Строки, ячейки и колонки внутри — внутренние, на вход не принимаются.
- `pageLink` создаёт подстраницу: `--text` — её название; в ответе `block.linkedPageId`.
- `database` вставкой не делается: `mynotion db create --inline` (группа баз).
- Картинки, файлы, видео вставляет `mynotion attachment add current --file … --as image` (группа библиотеки), не `block insert`.

## Поправить

Нужно что-то одно или несколько: `--text`/`--rich`, `--props`, `--kind`.

```bash
mynotion block update <id> --text 'Купить **кефир**'
mynotion block update <id> --kind heading2                  # превратить; текст остаётся
mynotion block update <id> --props '{"icon":"⚠️"}'          # значение null стирает свойство
```

- Превращаются друг в друга: `paragraph heading1 heading2 heading3 quote bulletItem numberedItem checkbox toggle callout code equation`. В остальные (`pageLink` и др.) — `invalid_argument`, допустимое — в `hint`.
- Превращение идёт по правилам окна: у выноски появляется иконка, у не-задачи пропадает отметка, заголовок теряет недопустимую вложенность.
- `rows` и `columns` при правке не меняются — только при вставке.

## Отметить, сдвинуть, переставить, удалить

```bash
mynotion block check <id>             # только checkbox; иначе invalid_argument
mynotion block uncheck <id>
mynotion block indent <id>            # Tab: не глубже соседа сверху + 1, не больше 8; вложенные едут вместе
mynotion block outdent <id>           # ⇧Tab; в ответе data.changed — сдвинулось ли
mynotion block move <id> --after <блок>     # или --first, --last; вложенные блоки едут вместе
mynotion block expand <id>            # только toggle; хранится на этом Mac, в историю страницы не пишется
mynotion block collapse <id>          # ответ: data.collapsed
mynotion block delete <id>            # блок и его вложенные; ответ: data.deleted — все удалённые id
```

- Последний блок страницы или колонки заменяется пустым абзацем: пустого места не остаётся.
- Части колонок и таблиц (`column`, `tableRow`, `tableColumn`, `tableCell`) отдельно не двигаются и не удаляются — только целая таблица или список колонок.
- `indent` у блока, который уже нельзя сдвинуть: `ok`, `data.changed: false`.

## На другую страницу

```bash
mynotion block move-to-page <id> --page Архив     # или id, путь
```

Блок и вложенные едут в конец страницы-цели. Ответ: `data.moved` — **новые** id блоков на странице-цели (старые перестают существовать), `data.pageId` — куда, `data.fromPageId` — откуда.

## Иконка и обложка

```bash
mynotion page icon current --emoji 🚀      # один эмодзи, составные (семья, флаг) тоже
mynotion page icon current --remove
mynotion page cover --list                  # галерея: data.gallery[] {id, title}
mynotion page cover current --gallery gradients_3            # id или название, регистр не важен
mynotion page cover current --gallery gradients_3 --offset 0.4   # сдвиг 0…1: 0 — верх картинки
mynotion page cover current --offset 0.7    # сдвинуть уже стоящую обложку
mynotion page cover current --file ~/Pictures/cover.png      # своя картинка, копируется во вложения
mynotion page cover current --remove
```

Ответ — страница целиком: `data.page.icon`, `data.page.cover` — `{"gallery":"gradients_3","offset":0.4}` или `{"attachmentId":"…","name":"cover.png","offset":0.5}`. Галерея сейчас: `solid_red solid_yellow solid_blue solid_beige gradients_2 gradients_3 gradients_4 gradients_5 gradients_8 gradients_10 gradients_11`.

## Ошибки

| Что сделано | Ответ |
|-------------|-------|
| `--kind nonsense` | `invalid_value`, список видов в `details.allowed` |
| `block check` на абзаце | `invalid_argument`: «Отметить можно только задачу», в `hint` как превратить |
| `block update --kind pageLink` у цитаты | `invalid_argument`, в `hint` какие виды превращаются |
| `page icon --emoji abc` | `invalid_value`: «Иконка — один эмодзи» |
| `page cover --gallery net-takoj` | `invalid_value`, вся галерея в `details.allowed` |
| страница в корзине | `page_in_trash` |
| блока нет | `block_not_found` |

## Пакет и отмена

- Несколько правок — одним `batch`; ошибка любого шага откатывает все. Шаг — `{"command":"block.check","args":{"block":"<id>"}}` (имя команды через точку):

```bash
echo '[{"command":"block.check","args":{"block":"01a16fb5-ce3b-…"}},{"command":"block.update","args":{"block":"01a16fb5-ce3b-…","text":"Новый"}}]' | mynotion batch
# первый шаг не прошёл (блок не задача) → {"ok":false,"error":{"code":"batch_failed","details":{"step":1,"command":"block.check",…},
#   "message":"Шаг 1 («block check»): … Пакет откачен"}} и блок остался как был
```

- Перед первой правкой страницы за 10 минут приложение само сохраняет версию «до правки агента». Правки агента не попадают в ⌘Z окон: вернуть можно через историю версий страницы.
- Правка видна в открытом окне сразу (замер на iMac: ~70 мс), курсор Юрия в другом блоке остаётся на месте.
