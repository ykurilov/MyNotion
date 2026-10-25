# Implementation Plan: Управление MyNotion из командной строки для агентов

**Branch**: `005-cli-control` | **Date**: 2026-10-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/005-cli-control/spec.md`

## Summary

Агент управляет MyNotion командой `mynotion` и скиллом. Команды выполняет запущенное приложение (вариант 1 Юрия):

- Приложение слушает Unix-сокет в своей папке: права только у владельца, проверка uid у каждого подключения (R1).
- Консольная команда — тонкий клиент внутри пакета приложения. Она разбирает аргументы по общему каталогу команд, при надобности поднимает приложение в фоне (`open -g`) и печатает JSON (R8, R9).
- Правки идут теми же операциями, что окно: `PageTreeOperations`, `PageDocument` через `OpenDocuments`, `DatabaseOperations` (R3). Поэтому окна, поиск, формулы и синхронизация видят их сразу.
- Перед правкой агента снимается версия «до правки агента» (R7). Пакет команд откатывается собственной отменой (R6).
- Markdown читается выгрузкой и пишется разбором импорта Notion (R5).
- Миграции базы нет, новых зависимостей нет.

## Technical Context

**Language/Version**: Swift 6 (swift-tools 6.2, язык v6, `SWIFT_STRICT_CONCURRENCY: complete`), Xcode 27 на iMac

**Primary Dependencies**: как в 004: SwiftUI, AppKit, GRDB 7. Новые модули — только Foundation, Darwin (`socket`, `getpeereid`), Dispatch, `os.Logger`. Новых сторонних зависимостей нет.

**Storage**: SQLite без изменений схемы. Новое — поле `agent` в JSON сводки версии (`page_version.summary`) и файл сокета `control.sock` рядом с базой.

**Testing**: Swift Testing для модулей на iMac (`imac-run … swift test --jobs 4`); один сквозной сценарий `scripts/imac/cli-e2e.zsh` на Release-сборке через `scripts/imac/run-on-imac.sh lock`; CuaDriver — снимки окна. Запасной путь — виртуальный Mac (`scripts/vm/run-in-vm.sh`).

**Target Platform**: macOS 26+, Apple Silicon (как 001–004)

**Project Type**: desktop-app + консольная команда в том же проекте

**Performance Goals**: ответ чтения и правки ≤ 150 мс p95 (SC-402); закрытое приложение → первый ответ ≤ 4 с (SC-402); окно показывает правку ≤ 1 с (SC-403)

**Constraints**: запуск ≤ 1 с и память в покое ≤ 200 МБ (конституция II). Сокет открывается после готовности библиотеки и в покое ничего не делает: прирост памяти ≤ 2 МБ, 0 % процессора (SC-406). Фокус Юрия не перехватывается без `--activate`. Успех правки означает, что она уже записана на диск.

**Scale/Scope**: один пользователь, его агенты; эталон 001–004 (дерево сотен страниц, база 10 000 строк); ≈ 95 команд в 9 группах (contracts/commands.md); 6 историй P1–P6

Неясностей не осталось: решения — в [research.md](research.md), допущения Q1–Q10 — в spec, Clarifications.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Принцип | Проверка | Итог |
|---------|----------|------|
| I. Только нужное | Задача Юрия 24.10.2026, вариант 1 выбран им. Охват — список задания. Не делается: настройки, вход синхронизации, ключ Notion, тема (spec, Assumptions), окно журнала (только системный журнал), режим «без окон» | ✅ |
| II. Лёгкость | Сокет — один `DispatchSource` после готовности библиотеки, в покое не работает. Своего потока, опроса и таймеров нет (R1, R13). Новых зависимостей нет. Разбор аргументов — свой, по каталогу (R9). Замер запуска и памяти — в конце этапов 1 и 8 (SC-406) | ✅ |
| III. macOS прежде всего | Unix-сокет и `open -g` — штатные средства macOS. Фокус не перехватывается. Окна и вкладки управляются теми же моделями, что ⌘T, ⌘[, ⌘] | ✅ |
| IV. Данные у владельца | Схема базы не меняется. Все записи идут операциями 001–004 (R3), ни одного своего SQL записи. «Успех» — после сохранения на диск. Перед правкой агента снимается версия (R7). Окончательное удаление — только с `--force`. Пакет откатывается целиком (R6). Импорт и выгрузка — те же пути, что в меню | ✅ |
| V. Ядро и добавки | Ядро получает только перенесённые из редактора чистые правила структуры блоков (R4). Остальное — новые модули `ControlProtocol`, `ControlServer`, `ControlCommands`, `ControlClient`, `PageMarkdown` и приложение `App/Control/`. Удалить их — значит убрать вход и команду, данные и окна не затронуты. Отдельный процесс (`mynotion`) — утверждённая потребность Юрия | ✅ |
| VI. Тесты по делу | TDD на каждый модуль. Тесты потерь: правка агента при незаписанном вводе Юрия (SC-403), откат пакета, версия до правки и восстановление, Markdown «прочитать → записать → прочитать» (SC-404), окончательное удаление без `--force`. Один сквозной сценарий, полный прогон — один раз в конце | ✅ |
| Технические рамки | Тяжёлых оболочек нет; сервер синхронизации не меняется | ✅ |

**Повторная проверка после проектирования**: модель данных добавила одно необязательное поле в JSON сводки версии — без миграции, старые версии читаются. Фоновая работа новая одна — ожидание подключения на сокете; задача в spec (FR-401, FR-405). Сеть не используется. ✅

## Project Structure

### Documentation (this feature)

```text
specs/005-cli-control/
├── spec.md
├── plan.md
├── research.md              # R1–R15
├── data-model.md
├── quickstart.md            # сквозной сценарий A, замеры
├── contracts/
│   ├── protocol.md          # связь, запрос, ответ, коды ошибок и выхода, справка
│   ├── commands.md          # каталог всех команд по группам и этапам
│   ├── block-json.md        # JSON страниц, блоков, ячеек, видов
│   └── coverage.md          # операция интерфейса → команда (SC-408)
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/MyNotionKit/Sources/
├── ControlProtocol/                  # новый, только Foundation: запрос, ответ, ошибки, каталог, разбор аргументов, кадры
│   ├── ControlRequest.swift, ControlResponse.swift, ControlErrorCode.swift
│   ├── CommandSpec.swift, CommandCatalog.swift, ArgumentParser.swift, LineFraming.swift
│   └── Catalog/ Service.swift Pages.swift Blocks.swift Databases.swift Library.swift Window.swift Transfer.swift
├── ControlServer/                    # новый: сокет, права, uid, очередь подключений
│   └── ControlSocketServer.swift, ControlSocketPath.swift, PeerCredentials.swift
├── ControlClient/                    # новый: подключение, запуск приложения, вывод для человека (тестируемая часть клиента)
│   └── SocketClient.swift, AppLauncher.swift, HumanOutput.swift, ExitCode.swift
├── ControlCommands/                  # новый: выполнение команд без окна
│   ├── CommandExecutor.swift, CommandSession.swift, WriteLock.swift, BatchRunner.swift, HandlerRegistry.swift
│   ├── ControlHost.swift, WindowControl.swift, AgentEditCheckpoint.swift, CommandLog.swift
│   ├── Locators/ PageLocator.swift BlockLocator.swift DatabaseRefs.swift
│   ├── Codecs/ PageJSON.swift BlockJSON.swift CellValueJSON.swift ViewJSON.swift
│   └── Handlers/ ServiceHandlers.swift PageHandlers.swift BlockHandlers.swift DatabaseHandlers/ LibraryHandlers.swift WindowHandlers.swift TransferHandlers.swift
├── PageMarkdown/                     # новый: страница ↔ Markdown (R5)
│   └── PageMarkdownReader.swift, MarkdownBlocksBuilder.swift
├── NotesCore/Document/BlockStructure.swift      # перенос чистых правил из PageEditor/BlockMoveController (R4)
├── NotionImport/ParsedBlockConverter.swift      # вынесено из NotionImporter (R5)
└── PageVersions/VersionDiff.swift, VersionPruning.swift   # поле agent, хранение отметок (R7)

Packages/MyNotionKit/Tests/
├── ControlProtocolTests/ ControlServerTests/ ControlClientTests/ PageMarkdownTests/
└── ControlCommandsTests/ Service… Pages… Blocks… Databases… Library… Window… Transfer… (по файлу на группу)

App/Control/
├── ControlBootstrap.swift            # старт сервера в конце openLibrary (R13)
├── AppControlHost.swift              # ControlHost поверх PagesLibrary
├── AppWindowControl.swift            # окна и вкладки (этап 6)
└── AppTransferControl.swift          # импорт, выгрузка, синхронизация (этап 7)

Tools/
├── mynotion/main.swift               # цель `mynotion` (tool): разбор → ControlClient → печать
└── mynotion-skill/ SKILL.md, references/{pages,blocks,databases,library,window,transfer}.md

scripts/install-cli.sh                # копия в /Applications, ссылка ~/.local/bin/mynotion, скилл, skill-doctor (R14)
scripts/imac/cli-e2e.zsh              # сквозной сценарий A
project.yml                           # цель mynotion, вложение в MyNotion.app/Contents/Helpers, тестовые цели в схеме
```

**Structure Decision**: модульный пакет, как в 001–004. Глубокие модули с тонкими входами:

- `ControlProtocol`: `CommandCatalog.parse(argv) -> ControlRequest`, `CommandCatalog.spec(for:)`;
- `ControlServer`: `start(path:handler:)`;
- `ControlCommands`: `CommandExecutor.execute(_ request) async -> AsyncStream<ControlResponseLine>`;
- `ControlClient`: `run(request, options) -> ExitCode`;
- `PageMarkdown`: `markdown(ofPage:)`, `drafts(fromMarkdown:)`.

Приложение знает только `ControlBootstrap.start(library:)`.

## Этапы и параллельность

Срезы вертикальные: после каждого этапа группа команд работает от терминала до окна.

| Этап | Что | Зависит от | Свои файлы (не пересекаются) |
|------|-----|-----------|------------------------------|
| **1. Основа** | Протокол, весь каталог команд (с заглушками `not_implemented`), сервер, клиент и запуск приложения, исполнитель с замком записи, сессия, `batch` с откатом, версия «до правки агента», указатели, кодеки JSON, хост и протокол окна, старт в приложении, цели в `Package.swift` и `project.yml` (все новые модули и тесты сразу), `app status`, `commands`, журнал, главный файл скилла и установка | — | всё общее |
| **2. Страницы и Markdown (US1, MVP)** | `page …`, `trash …`, `PageMarkdown`, вынос `ParsedBlockConverter` | 1 | `Handlers/PageHandlers.swift`, `PageMarkdown/`, `NotionImport/ParsedBlockConverter.swift` + `NotionImporter.swift`, `references/pages.md` |
| **3. Блоки, иконки, обложки (US2)** | `block …`, `page icon`, `page cover`, перенос правил в `BlockStructure` | 1 | `Handlers/BlockHandlers.swift`, `NotesCore/Document/BlockStructure.swift`, `PageEditor/BlockMoveController.swift`, `references/blocks.md` |
| **4. Базы (US3)** | `db …` | 1 | `Handlers/DatabaseHandlers/`, `references/databases.md` |
| **5. Поиск, избранное, недавние, шаблоны, история, вложения (US4)** | `search`, `favorites`, `recents`, `template`, `history`, `attachment` | 1, 2 (`history show` берёт `PageMarkdown`) | `Handlers/LibraryHandlers.swift`, `references/library.md` |
| **6. Окно (US5)** | `window`, `open`, `tab`, `nav` | 1 | `Handlers/WindowHandlers.swift`, `App/Control/AppWindowControl.swift`, `references/window.md` |
| **7. Импорт, выгрузка, синхронизация (US6)** | `import`, `export`, `db export`, `sync` | 1 | `Handlers/TransferHandlers.swift`, `App/Control/AppTransferControl.swift`, `references/transfer.md` |
| **8. Итог** | сверка охвата (SC-408), сквозной сценарий A, полный прогон один раз, замеры, ревью, проверка скилла агентом (SC-401), установка на iMac; на основной Mac — с согласия Юрия | 2–7 | — |

Параллельно (не больше трёх, каждый в своём worktree):

- **Волна A** после этапа 1: этапы 2, 3, 4.
- **Волна B**: этапы 6 и 7 стартуют, как только освободится место в волне A. Этап 5 — после вливания этапа 2.

Вливание — по одному, с затронутыми тестами после каждого. Каталог команд, `Package.swift`, `project.yml`, `HandlerRegistry.swift` и главный `SKILL.md` правит только этап 1. Если этапу 2–7 нужен новый флаг, он правит только свой файл `Catalog/<Группа>.swift`.

Шаблоны строк баз (`db template …`) зависят от 004 US6 (T097, ещё не влит). Если к этапу 4 их нет, команды остаются `not_implemented`, а в tasks это отдельная задача после вливания 004 US6.

Темп агентов (оценка):

| Этап | Время работы агента |
|------|---------------------|
| 1 | ≈ 70 мин |
| Волна A (самый долгий — этап 4) | ≈ 60 мин |
| Волна B | ≈ 40 мин |
| 8 | ≈ 50 мин |

Итого ≈ 3,5–4 ч работы агентов.

## Complexity Tracking

Нарушений конституции нет.
