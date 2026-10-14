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
| `--generate-visual-sample` | добавить в открытую базу страницу «MyNotion — образец» для сверки с Notion |
| `--launch-report <путь>` | записать в файл время запуска и память в покое (для замеров) |

## Сервер синхронизации (появится в этапе 7)

```sh
cd server && pnpm install && pnpm dev   # http://localhost:8787/health → ok
```
