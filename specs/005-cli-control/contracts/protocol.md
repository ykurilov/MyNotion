# Контракт: протокол команд, ответ, ошибки

Общая часть всех команд. Закрепляется на этапе 1 (Foundation) и дальше не меняется без новой версии протокола.

## Связь

- Сокет: `~/Library/Application Support/MyNotion/control.sock`, права `0600`, владелец проверяется у каждого подключения (research R1).
- Другой путь: `--socket <путь>` или `MYNOTION_SOCKET` (тесты, `--database`).
- Кадр — одна строка UTF-8 JSON, конец — `\n`. Одно подключение — один запрос; клиент закрывает связь после итоговой строки.
- Предел запроса — 64 МБ. Markdown и пачки строк идут внутри JSON. Файлы (вложения, импорт, выгрузка) передаются путями: приложение и команда работают под одним пользователем на одном Mac.

## Запрос

```json
{
  "protocol": 1,
  "id": "c0a8…",                         // любой текст клиента, возвращается в ответе
  "command": "page.create",              // группа.действие из каталога
  "args": { "parent": "Проекты", "title": "Встреча 24.10" },
  "agent": "Codex",                      // --agent или MYNOTION_AGENT; по умолчанию "агент"
  "timeoutMs": 30000,                    // --timeout; по умолчанию 30 000, для import/export — 600 000
  "cwd": "/Users/ykurilov/work",         // папка клиента: относительные пути файлов считаются от неё
  "human": true                          // только с --human: приложение добавит в ответ строку "text"
}
```

## Ответ

Итоговая строка:

```json
{ "id": "c0a8…", "ok": true,  "data": { … }, "warnings": [ { "code": "markdown_unsupported", "message": "…", "line": 12 } ] }
{ "id": "c0a8…", "ok": false, "error": { "code": "page_not_found", "message": "Страница «Проекты/Встрча» не найдена", "hint": "Проверьте путь: mynotion page tree --depth 2", "details": { … } } }
```

С `human` в итоговой строке есть `"text": "✓ Создана «Встреча 24.10» (3f2a91c0) в «Проекты»"` — её печатает `--human`; без неё клиент печатает данные сам.

Ход долгой команды (до итоговой): `{"id":"…","progress":{"done":120,"total":900,"stage":"Страницы"}}`.

Списки внутри `data`: `{"items":[…],"nextCursor":"…"|null}`. По умолчанию `--limit 200`, наибольший — 1 000.

Изменяющая команда возвращает изменённый объект целиком (`data.page`, `data.block`, `data.row`, `data.property`, `data.view`). Удаление в корзину возвращает `{"id":…,"inTrash":true}` (FR-431).

## Коды ошибок и коды выхода

| Группа | Код выхода | Коды |
|--------|-----------|------|
| Неверный вызов | 2 | `unknown_command`, `invalid_argument`, `missing_argument`, `invalid_value`, `invalid_markdown`, `invalid_formula`, `not_batchable`, `force_required` |
| Не найдено | 3 | `page_not_found`, `block_not_found`, `database_not_found`, `property_not_found`, `option_not_found`, `view_not_found`, `row_not_found`, `version_not_found`, `attachment_not_found`, `file_not_found`, `window_not_found`, `tab_not_found`, `template_not_found` |
| Конфликт | 4 | `ambiguous_page`, `page_in_trash`, `cannot_move` (в свою ветку), `wrong_page` (блок не этой страницы), `read_only_property`, `window_busy`, `batch_failed`, `not_implemented`, `sync_disabled` (`sync now` при выключенной синхронизации) |
| Приложение недоступно | 5 | `app_not_running` (при `--no-launch`), `app_not_ready`, `app_disconnected`, `timeout`, `version_mismatch` |
| Внутренняя | 1 | `internal`, `write_failed` |

Сообщение — по-русски, одно предложение. Подсказка — что сделать, часто готовая команда. В `details` — то, что нужно агенту для следующего шага: кандидаты, допустимые значения, номер шага пакета.

Предупреждения (`warnings`) не делают команду неуспешной: `markdown_unsupported`, `option_created`, `value_converted`, `truncated`, `not_moved` (импорт прошёл, но в указанную страницу не перенесён), `partial_rollback` (откат после ошибки не тронул блоки, которые после команды правили в окне или синхронизация; либо не вернул свойство базы).

## Вывод для человека (`--human`)

Одна-две строки на объект: `✓ Создана «Встреча 24.10» (3f2a91c0) в «Проекты»`. Дерево — отступами, таблица строк — колонками по ширине терминала. Ошибка: `✗ <сообщение>` и `→ <подсказка>` в stderr.

## Справка

- `mynotion --help` — группы и общие флаги.
- `mynotion <группа> --help` — действия группы.
- `mynotion <группа> <действие> --help` — назначение, аргументы с типами, флаги, пример.
- `mynotion commands --json` — весь каталог (contracts/commands.md) машинно.

Справка работает без запуска приложения.

## Общие флаги

`--human`, `--agent <имя>`, `--timeout <мс>`, `--no-launch`, `--launch-timeout <с>` (15), `--socket <путь>`, `--include-trashed`, `--limit`, `--cursor`, `--help`, `--version`.

## Версия

`protocol` — целое. Если приложение не знает версию клиента, ответ `version_mismatch` с `details: {"app": "…", "client": "…"}`. `mynotion --version` печатает версию клиента и, если приложение запущено, его версию.
