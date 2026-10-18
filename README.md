# MyNotion

Личное приложение заметок для macOS: дерево страниц, блоки текста, автосохранение.
Требования, план и задачи — в [specs/001-core-pages-editor/](specs/001-core-pages-editor/).
Правила проекта — в [.specify/memory/constitution.md](.specify/memory/constitution.md).

## Что нужно

- Mac на Apple Silicon, macOS 26 или новее.
- Xcode 26, XcodeGen (`brew install xcodegen`).
- Для сервера синхронизации — Node.js 22 и pnpm.

## Сборка и запуск

Проект Xcode не хранится в репозитории: он создаётся из `project.yml`.

```sh
xcodegen generate
xcodebuild build -scheme MyNotion -destination 'platform=macOS,arch=arm64'
```

## Тесты

```sh
# Модули (Swift Testing) — быстро, без Xcode-проекта
cd Packages/MyNotionKit && swift test

# Все модули и сценарии XCUITest
xcodebuild test -scheme MyNotion -destination 'platform=macOS,arch=arm64'

# Замеры бюджета (запуск ≤ 1 с, память ≤ 200 МБ) — сборка Release на эталонной базе.
# PerformanceTests запускает приложение через систему, как Dock; PerformanceUITests — замеры через XCUITest.
xcodebuild test -scheme MyNotionPerformance -configuration Release -destination 'platform=macOS,arch=arm64'
```

## Флаги запуска

| Флаг | Что делает |
|------|------------|
| `--database <путь>` | открыть базу из указанного файла вместо `~/Library/Application Support/MyNotion/MyNotion.sqlite` |
| `--generate-reference-library <путь>` | создать эталонную базу (1 000 страниц, 100 000 блоков) и выйти |
| `--generate-visual-sample` | добавить в открытую базу страницу «MyNotion — образец» для сверки с Notion и открыть её |
| `--launch-report <путь>` | записать в файл время запуска и память в покое (для замеров) |
| `--window-snapshot <путь>` | когда страница готова, снять окно в PNG и выйти (работает и при заблокированном экране) |
| `--ui-gallery <папка>` | на своей временной базе снять все состояния интерфейса (светлая и тёмная тема, 1440×900, ключевые ещё 900×700), положить рядом `index.html` и `manifest.json` и выйти |
| `--ui-gallery-only <часть имени>` | вместе с `--ui-gallery`: снять только состояния, в имени которых есть эта строка |
| `--appearance light\|dark` | светлая или тёмная тема вместо системной |
| `--search-benchmark <путь>` | замер поиска (T054, SC-009): слова печатаются в поле поиска по букве, время от нажатия до выдачи на экране; отчёт с p95 в файл и выход |
| `--typing-benchmark <путь>` | замер отклика: 200 нажатий в странице на 1 000 блоков, переходы между страницами, набор и прокрутка страницы на 10 000 блоков; отчёт с p95 в файл и выход |
| `--sync-server <адрес>`, `--sync-device-name <имя>` | живая проверка синхронизации: адрес сервера и имя Mac без окна настроек |
| `--sync-connect-token-file <путь>` | подключить как первый Mac токеном из файла (файл стирается) |
| `--sync-write-join-code <путь>` | после подключения записать код для второго Mac в файл |
| `--sync-log <путь>` | вместе с флагами выше: писать ход синхронизации в файл |
| `--sync-join-code-file <путь>` | подключить кодом из файла (ждёт, пока файл появится); вместе — `scripts/vm/sync-live-check.sh` |
| `--export-markdown <папка>` | выгрузить все записи в Markdown в `<папка>/MyNotion-выгрузка-<дата>/` без окна выбора папки, напечатать путь и выйти (код 0 — готово, 1 — ошибка, частичной папки не остаётся) |

**Служебные режимы не берут фокус.** Галерея, снимки окна, замеры и эталонная база (`--ui-gallery`, `--ui-gallery-only`, `--window-snapshot`, `--hover-sidebar-row`, `--generate-reference-library`, `--launch-report`, `--typing-benchmark`, `--search-benchmark`, `--export-markdown`, а также `--generate-visual-sample` вместе с ними) идут, пока человек работает в других программах. Приложение не становится активным, не стоит в Dock, его окна лежат под всеми окнами. Нигде в этих режимах нет `activate`, `makeKeyAndOrderFront` и `orderFrontRegardless`. Новый служебный флаг обязан работать так же: он добавляется в `LaunchPresence.serviceFlags` (модуль `ServiceLaunch`) и в его тест. Запуск без служебных флагов — обычное приложение.

## Сервер синхронизации (появится в этапе 7)

```sh
cd server && pnpm install && pnpm dev   # http://localhost:8787/health → ok
```

## Запуск только в виртуальном Mac

На основном Mac приложение не запускается ни в каком виде — это мешает Юрию работать. Сборка на основном Mac разрешена, запуск — только внутри виртуального Mac (Cua/Lume, машина `cua-base-3416f98dedcf` на SSD):

```sh
scripts/vm/run-in-vm.sh gallery [--only <слово>] [--out <папка>]   # галерея состояний, снимки копируются сюда
scripts/vm/run-in-vm.sh run <флаги приложения>                       # любой служебный режим
scripts/vm/run-in-vm.sh ssh <команда>                                # команда внутри
scripts/vm/run-in-vm.sh status
```

Экран виртуального Mac — 1512×982 точек с ретиной (`lume set … --display 3024x1964`), Dock прячется. Тогда окно галереи 1440×900 влезает целиком, а снимки, как на ноутбуке, вдвое крупнее (@2x). Сам гость после перезапуска ставит 1024×768, поэтому `gallery` перед съёмкой включает нужный режим программой `scripts/vm/displaymode.swift`.
