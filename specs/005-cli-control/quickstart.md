# Quickstart: проверка управления из командной строки

Всё запускается на iMac (`imac-run`, skill imac). На основном Mac Юрия ничего не собирается и не запускается, кроме последнего шага установки — по согласию Юрия.

## Подготовка

```bash
# модули — без окна
cd Packages/MyNotionKit && imac-run --no-fallback --wait 1800 --no-setup -- \
  swift test --jobs 4 --filter 'ControlProtocolTests|ControlServerTests|ControlCommandsTests|PageMarkdownTests'

# Release-сборка с командой внутри пакета и сквозной сценарий (окно → место «экран»)
scripts/imac/run-on-imac.sh lock -- zsh scripts/imac/cli-e2e.zsh
```

`cli-e2e.zsh` собирает Release, кладёт команду в `$WORK/bin/mynotion`, запускает приложение на эталонной базе (`--database $WORK/e2e.sqlite`, сокет `$WORK/s.sock`). Шаги сценария — ниже, каждый сверяет JSON (`jq -e`). Снимки окна — CuaDriver в `~/work/shots/005/`.

## Сценарий A — сквозной (один на фичу)

| Шаг | Команда | Ожидается |
|-----|---------|-----------|
| 1 | приложение закрыто; `mynotion page tree --depth 1` | приложение поднялось в фоне, переднее приложение не сменилось (`lsappinfo front`), JSON с деревом, ≤ 4 с |
| 2 | `page create --parent Проекты --title "Встреча 24.10" --markdown fixtures/meeting.md` | `ok`, `data.page.id` |
| 3 | `page read <id>` | Markdown совпадает с `meeting.md` после выгрузки (SC-404) |
| 4 | `open <id> --new-tab`; снимок | вкладка открыта, фокус у терминала |
| 5 | `block insert <id> --kind callout --text "Итог" --after <2-й блок>`; `block check <задача>`; `block indent <пункт>`; снимок | окно показывает все три правки ≤ 1 с (SC-403) |
| 6 | `page icon <id> --emoji 🚀`; `page cover <id> --gallery gradient-3` | иконка и обложка в окне |
| 7 | `db create --parent <id> --title Задачи --inline`; `db prop add … --type status`; `db prop add … --type date`; `db row add --rows fixtures/rows.json` (50); `db view update --filter … --sort … --group Статус`; `db rows --view` | порядок и группы как в окне |
| 8 | `batch` из трёх шагов, третий с ошибкой | `batch_failed`, шаг 3; данные как до пакета |
| 9 | `history list <id>` | есть версия `agent: "e2e"`; `history restore` возвращает страницу к шагу 2 |
| 10 | `search "Встреча"`; `favorites add <id>`; `recents` | выдача как в окне |
| 11 | `page trash <id>`; `page restore <id>`; `trash delete <id>` без `--force` | `force_required` |
| 12 | `export page <id> --to $WORK/out` | файлы как у выгрузки из меню |
| 13 | `mynotion --no-launch app status` после `quit` | `app_not_running`, код выхода 5 |

## Проверки этапов (без сквозного)

- Этап 1: `mynotion commands --json` — весь каталог; `mynotion page tree` до этапа 2 — `not_implemented`; права сокета `0600`; клиент запускает приложение и ждёт; замер запуска и памяти в покое — не хуже 004 больше чем на шум (SC-406).
- Этапы 2–7: тесты своей группы зелёные; одна живая команда группы на iMac против Release-сборки; файл скилла `references/<группа>.md` с примерами, которые сами выполнены.
- Этап 8: сверка `coverage.md` тестом; полный прогон всех тестов один раз; сценарий A; замеры SC-402, SC-406; агент Sonnet без знания MyNotion выполняет 10 задач по скиллу (SC-401).

## Замеры

| Что | Как | Цель |
|-----|-----|------|
| Ответ чтения и правки | 200 вызовов `page get`, `block update` подряд на эталоне 004, p95 | ≤ 150 мс (SC-402) |
| Запуск командой | приложение закрыто → первый ответ | ≤ 4 с (SC-402) |
| Запуск и память в покое | сценарии 001 на Release | ≤ 1 с, ≤ 200 МБ, прирост ≤ 2 МБ (SC-406) |
| Покой | `top -l 5 -pid` при открытом сокете без команд | 0 % процессора |

### Итоги этапа 1 (iMac, Release, 25.10.2026, `scripts/imac/cli-live-check.zsh`)

| Что | 005 | 004 (3c35fe6) |
|-----|-----|---------------|
| Запуск командой: приложение закрыто → ответ `app status` | 1,41 с; 3,03 с при нагрузке iMac ≈ 19 (чужие тесты); фокус не ушёл | — |
| Память в покое, пустая база, 10 с, три запуска (`footprint`) | 28 / 27 / 29 МБ; повтор 28 / 28 / 28 МБ | 29 / 28 / 28 МБ; повтор 28 / 28 / 28 МБ |
| Процессор в покое с открытым сокетом | 0 % | — |

Прирост памяти от сокета и исполнителя — в пределах разброса запусков (≤ 2 МБ). Ответ чтения и правки (p95) — на этапе 2, когда появятся `page get` и `block update`.
