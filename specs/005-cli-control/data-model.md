# Data Model: Управление из командной строки

Схема базы MyNotion не меняется: миграции нет. Новое — типы протокола (в памяти и на проводе) и одно поле в JSON сводки версии.

## Типы протокола (`ControlProtocol`, без зависимостей)

**ControlRequest** — `protocol: Int`, `id: String`, `command: String` (`группа.действие`), `args: JSONValue` (объект), `agent: String?`, `timeoutMs: Int?`, `cwd: String?`.
Проверка: `command` есть в каталоге; аргументы — по `CommandSpec` (обязательные, типы, взаимоисключающие флаги) до выполнения.

**ControlResponse** — `id`, `ok: Bool`, `data: JSONValue?`, `error: ControlError?`, `warnings: [ControlWarning]`. Промежуточная строка — `ControlProgress {done, total?, stage}`.

**ControlError** — `code: ControlErrorCode`, `message: String` (рус.), `hint: String?`, `details: JSONValue?`.
**ControlErrorCode** — закрытый `enum` (contracts/protocol.md) со свойством `group` → код выхода клиента.

**CommandSpec** — `group`, `action`, `summary`, `arguments: [ArgumentSpec]` (имя, тип: `page|block|database|property|view|option|row|version|string|int|json|file|bool|enum(…)`, обязательный, позиционный или флаг, по умолчанию), `access: read|write`, `batchable: Bool`, `example: String`, `stage: Int` (этап, где появляется обработчик).
**CommandCatalog** — все `CommandSpec`; по нему клиент делает справку и разбор, приложение — проверку.

Состояния команды на стороне приложения: `received → validated → (waiting for write lock) → running → done | failed`. Разрыв связи после `running` не отменяет выполнение (research R2).

## Указатели (`ControlCommands`)

**PageLocator** — `.id(UUID)`, `.idPrefix(String)` (≥ 8 знаков), `.current`, `.path([String])`. Разрешение → `UUID` или ошибка `page_not_found | ambiguous_page(candidates) | page_in_trash`.
**BlockLocator** — `UUID`; проверка, что блок на указанной странице (`wrong_page`).
**DatabaseLocator** = PageLocator, страница вида `database`. **PropertyRef**, **ViewRef**, **OptionRef**, **RowRef** — имя или id внутри базы. Неоднозначное имя — ошибка со списком.

## Кодеки (`ControlCommands/Codecs/`)

`PageJSON`, `BlockJSON`, `CellValueJSON` (по `PropertyKind`), `ViewJSON` (фильтр, сортировка, группировка с именами свойств ↔ `FilterNode`/`SortSpec`/`GroupSettings` с id). Формат — contracts/block-json.md. Свойство кодеков: `decode(encode(x)) == x` для всех видов блоков и типов свойств (тесты этапа 1).

## Сессия команды

**CommandSession** (`@MainActor`) — живёт одну команду или один пакет: свой `UndoManager` (не окна), имя агента, накопленные `warnings`, набор затронутых страниц (для обновления окон и версии «до правки агента»).

## Версия «до правки агента»

`VersionSummary` (`Src/PageVersions/VersionDiff.swift`) получает поле `agent: String?` (декодируется как необязательное; старые версии — `nil`). `VersionStamp` получает `isAgentCheckpoint`, прореживание (`VersionPruning`) хранит такие версии наравне с `isBeforeRestore`.

**AgentEditCheckpoint** — правило: перед первой записью в страницу P от агента A, если у P нет версии с `agent != nil` моложе 10 минут, — снять версию P с `agent = A`. Время — от часов `NotesStore` (подменяются в тестах).

## Окно (`WindowControl`, протокол в `ControlCommands`)

`windows() -> [WindowInfo {index, isFront, tabs: [TabInfo {index, pageId, title, isSelected}], canGoBack, canGoForward, isBusy}]`; `open(pageId, placement: current|newTab|newWindow, blockId?, activate)`; `newTab`, `selectTab`, `closeTab`, `reopenTab`, `back`, `forward`. Реализация — `App/Control/AppWindowControl.swift`; в тестах — подставная.

## Хост приложения (`ControlHost`, протокол в `ControlCommands`)

То, что есть только у приложения: `library` (store, attachments, openDocuments), `treeDidChange()`, `refreshAfterDirectWrite(pages:)` (обновить окна после правки мимо документа), `windowControl`, `importer`, `exporter`, `sync`. Тесты подставляют хост на временной базе.
