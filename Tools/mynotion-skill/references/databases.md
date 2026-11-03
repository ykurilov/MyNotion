# Базы данных

База — страница со свойствами (колонками), строками (страницами-детьми) и видами (таблицами со своими фильтрами).
Указатель базы — как у страницы (`Проекты/Задачи`, id). Страница с одной встроенной базой тоже подходит.
Свойство, вариант и вид — имя (регистр и ё/е не важны) или id. Строка — название или id.

## С чего начать

```bash
mynotion db schema Проекты/Задачи --agent Codex          # свойства, варианты, виды
mynotion db rows Проекты/Задачи --limit 50 --agent Codex  # строки первого вида
```

## Значения ячеек

Ключи — имена свойств. «Название» — название строки.

| Тип | Значение | Пример |
|-----|----------|--------|
| `title`, `url`, `email`, `phone` | строка | `"Отчёт"` |
| `text` | Markdown строки | `"Купить **молоко**"` |
| `number` | число | `42.5` |
| `checkbox` | `true` / `false` | `true` |
| `select`, `status` | имя варианта | `"В работе"` |
| `multiSelect` | массив имён | `["А","Б"]` |
| `date` | `ГГГГ-ММ-ДД` или `{start, end, time, remind}` | `"2026-10-24"`, `{"start":"2026-10-24T09:30","end":"2026-10-25T10:00"}` |
| `files` | id вложений или `{url, name}` | `[{"url":"https://…/f.pdf","name":"f.pdf"}]` |
| `relation` | названия или id строк другой базы | `["Альфа"]` |

- `null` — очистить ячейку.
- Нового варианта выбора нет — он создаётся, в ответе предупреждение `option_created`. Вариант статуса не создаётся: `option_not_found`.
- `formula`, `rollup`, `createdTime`, `lastEditedTime`, `uniqueId` вычисляются сами: запись — `read_only_property`.
- Неверное значение — `invalid_value`, в `details` есть `type`, `expected` и `example`.
- В ответе вычисляемые — `{value, display}`, связь — `[{id, title}]`.

## Строки

```bash
mynotion db row add Задачи --values '{"Название":"Отчёт","Часы":2,"Статус":"В работе"}'
mynotion db row add Задачи --rows rows.json        # массив объектов, до 1 000; файл или - (stdin)
mynotion db row update Задачи Отчёт --values '{"Статус":"Готово"}'
mynotion db cell set Задачи Отчёт Срок --value '"2026-10-24"'
mynotion db row trash Задачи Отчёт Звонок          # restore — вернуть, duplicate — копии
mynotion db relation link Задачи Отчёт Клиент --to Альфа --to Бета   # unlink — убрать
```

```json
{"ok":true,"data":{"count":1,"row":{"id":"…","title":"Отчёт","values":{"Часы":2,"Статус":"В работе"}},
  "rows":[{"id":"…","title":"Отчёт","values":{"Часы":2,"Статус":"В работе"}}]}}
```

- `count` — сколько строк добавлено, `rows` — они же целиком (`id`, `title`, `values`). `row` — одна строка, только когда добавляли одну (без `--rows`).
- Пачка пишется одним шагом. Ошибка в любой строке не пишет ничего: `error.details.row` — номер строки с нуля.
- Значение связи в `--values` задаёт весь набор. `relation link`/`unlink` добавляют и убирают по одной.

## Строки по виду

```bash
mynotion db rows Задачи --view Срочные
mynotion db rows Задачи --filter '{"property":"Статус","operator":"isNot","value":"Готово"}' \
  --sort '[{"property":"Срок","direction":"ascending"}]' --search отчёт --properties Статус,Срок
```

- Порядок и группы — как в таблице приложения. Без `--view` — первый вид.
- `--filter`, `--sort`, `--search` — только для этого ответа, в вид не пишутся.
- Ответ: `{view, total, groups:[{key, id, count, collapsed, rows:[{id, title, values}]}], nextCursor}`. Без группировки — одна группа с `key: null`.
- Части: `--limit` до 1 000, дальше `--cursor <nextCursor>`. Скрытые группы в ответ не входят.

## Фильтр и сортировка

- Условие: `{"property":"Часы","operator":"greaterThan","value":2}`. Группы: `{"and":[…]}`, `{"or":[…]}`, вложенные.
- Варианты в условии — именами.
- Условие не к типу свойства — `invalid_value`, подходящие в `details.allowed`.
- Сортировка — массив `[{"property":"…","direction":"ascending|descending"}]`, по порядку уровней.

Условия по типам:

| Тип | Условия |
|-----|---------|
| текст, url, почта, телефон, формула, сводка | `is`, `isNot`, `contains`, `doesNotContain`, `startsWith`, `endsWith`, `isEmpty`, `isNotEmpty` |
| число | `equals`, `notEquals`, `greaterThan`, `lessThan`, `greaterThanOrEqual`, `lessThanOrEqual`, `isEmpty`, `isNotEmpty` |
| ID | те же, что у числа, без `isEmpty` и `isNotEmpty` |
| выбор, статус | `is`, `isNot`, `isEmpty`, `isNotEmpty`; у статуса ещё `isInGroup` |
| множественный выбор, связь | `contains`, `doesNotContain`, `isEmpty`, `isNotEmpty` |
| дата | `is`, `isBefore`, `isAfter`, `isOnOrBefore`, `isOnOrAfter`, `isBetween`, `isRelativeToToday`, `isEmpty`, `isNotEmpty` |
| флажок | `is` |
| файлы | `isEmpty`, `isNotEmpty` |

Точный список для свойства — из ошибки `invalid_value` (`details.allowed`).

## Виды

```bash
mynotion db view list Задачи
mynotion db view add Задачи --name Срочные          # rename --name, duplicate, delete, move --first|--after
mynotion db view update Задачи Срочные \
  --filter '{"and":[{"property":"Статус","operator":"isNot","value":"Готово"},{"or":[…]}]}' \
  --sort '[{"property":"Часы","direction":"descending"}]' \
  --group '{"property":"Статус","sort":"manual","hideEmpty":false}' \
  --hidden Теги --order Часы,Статус --width Часы=140 --wrap on --calc Часы=sum \
  --open-in center --load-limit 25
mynotion db view update Задачи Срочные --group-hide Готово --group-collapse "В работе" --group-order "В работе,Нет «Статус»"
mynotion db view update Задачи Срочные --order-rows Счёт --after Отчёт
```

- `--filter null`, `--group null`, `--sort null` — убрать.
- Группа — по заголовку (`Готово`, `Нет «Статус»`, `Без даты`) или по `id` из `db rows`.
- `--calc` — функция итога колонки (`sum`, `average`, `countAll`…), `none` — убрать.
- `--load-limit` — 10, 25, 50 или 100.
- `--order-rows` — ручной порядок строк (без `--after` — первой). Действует, пока у вида нет сортировки.

## Схема

```bash
mynotion db create --parent Проекты --title Задачи            # --inline [--after <блок>] — внутри страницы
mynotion db prop add Задачи --name Часы --type number --config '{"format":"number","decimals":1}'
mynotion db prop add Задачи --name Клиент --type relation --config '{"target":"Проекты/Клиенты","limit":"one","related":"Задачи"}'
mynotion db prop add Задачи --name Сводка --type rollup --config '{"relation":"Клиент","property":"Название","calculation":"countAll"}'
mynotion db prop add Задачи --name Итого --type formula --config '{"formula":"prop(\"Часы\") * 2"}'
mynotion db prop update Задачи Итого --formula 'prop("Часы") * 3'
mynotion db prop type Задачи Метка --type text       # значения переводятся
mynotion db prop move Задачи Срок --after Статус      # duplicate, delete, restore
mynotion db option add Задачи Статус Ревью --group inProgress --color purple
mynotion db option move Задачи Статус Ревью --group complete   # rename --name, color --color, delete
```

- `db create` создаёт базу только со свойством «Название» и одним видом «Таблица». Остальное добавляет `db prop add`.
- Новое свойство `status` само получает варианты «Не начато» (группа `todo`), «В работе» (`inProgress`), «Готово» (`complete`). Свои — `db option add`.
- Типы: `title`, `text`, `number`, `select`, `multiSelect`, `status`, `date`, `checkbox`, `url`, `email`, `phone`, `files`, `createdTime`, `lastEditedTime`, `relation`, `rollup`, `formula`, `uniqueId`.
- Связь: `target` — база, `limit` — `one` или `none`, `related` — имя ответного свойства в другой базе. `related: false` убирает ответное свойство.
- Сводка: `relation` — свойство-связь, `property` — свойство в связанной базе, `calculation` — функция (`showOriginal`, `countAll`, `sum`…).
- Формула — текстом с именами свойств. Ошибка — `invalid_formula`, место в тексте — `details.from` и `details.to`.
- Прочие ключи `config` пишутся как есть: число — `format`, `decimals`, `showAs`; дата — `dateFormat`, `timeFormat`; ID — `prefix`.
- Смена типа на базе от 1 000 строк идёт в фоне. Ответ приходит после её конца.
- Удалённое свойство возвращает `db prop restore`.

## Шаблоны строк

```
mynotion db template list Задачи                       # шаблоны, какой из них по умолчанию
mynotion db template add Задачи --title 'Еженедельная' # пустой шаблон; значения: db cell set <база> <id шаблона> …
mynotion db template default Задачи Еженедельная       # по умолчанию; --none — «Пустая»
mynotion db template duplicate Задачи Еженедельная     # «Еженедельная (1)» сразу за оригиналом
mynotion db template delete Задачи Еженедельная
mynotion db template apply Задачи Отчёт Еженедельная   # шаблон на пустую строку
mynotion db row add Задачи --template Еженедельная --values '{"Название":"Отчёт"}'
```

- Шаблон — по названию или id. Нет такого — `template_not_found`.
- Шаблона нет в `db rows`, поиске и дереве. Тело и значения шаблона правятся по его id: `page append`, `db cell set`.
- `db row add` без `--template` берёт шаблон по умолчанию базы. Значения команды ложатся поверх шаблона. «Сегодня» и «Сейчас» у дат шаблона становятся моментом создания.
- `db template apply` кладёт шаблон только на пустую строку (нет текста и подстраниц), иначе `invalid_value`. Название строки остаётся своим.
- `db template delete` убирает шаблон в корзину; был по умолчанию — по умолчанию снова «Пустая».
