import AIModels
import ControlProtocol
import Foundation
import Synchronization
import Testing
@testable import AIAgent

/// Подменный исполнитель команд: запоминает запросы, отвечает заданным.
final class FakeCommands: Sendable {
    private let requests = Mutex<[ControlRequest]>([])
    private let reply: @Sendable (ControlRequest) -> ControlResponse

    init(reply: @escaping @Sendable (ControlRequest) -> ControlResponse = { .success($0.id, ["ok": true]) }) {
        self.reply = reply
    }

    var seen: [ControlRequest] { requests.withLock { $0 } }

    var runner: NoteToolbox.Runner {
        { [self] request in
            requests.withLock { $0.append(request) }
            return reply(request)
        }
    }
}

@Suite("Инструменты агента из каталога команд")
struct NoteToolboxTests {
    private func tool(_ name: String) throws -> ModelTool {
        try #require(NoteToolbox.tools.first { $0.name == name }, "Нет инструмента \(name)")
    }

    @Test("Чтение, поиск, создание, правка, перенос страниц и блоков, базы — есть")
    func included() throws {
        for name in ["page_tree", "page_read", "page_create", "page_write", "page_append", "page_rename", "page_move", "page_trash",
                     "page_restore", "search", "block_insert", "block_update", "block_move", "block_move-to-page", "block_delete",
                     "db_create", "db_schema", "db_rows", "db_row_add", "db_row_update", "db_cell_set", "db_view_update", "open"] {
            _ = try tool(name)
        }
    }

    @Test("Удалить навсегда, пакеты, файлы, синхронизация, окна — нет")
    func excluded() {
        let names = Set(NoteToolbox.tools.map(\.name))
        for name in ["trash_delete", "trash_empty", "batch", "sync_now", "sync_status", "import_notion", "export_all", "export_page",
                     "attachment_add", "attachment_get", "db_export", "page_cover", "page_share", "window_state", "tab_new", "nav_back",
                     "app_status", "commands"] {
            #expect(!names.contains(name), "Лишний инструмент \(name)")
        }
    }

    @Test("Каждый инструмент — команда каталога; имена годятся всем поставщикам; порядок постоянный")
    func names() {
        for name in NoteToolbox.commandNames { #expect(CommandCatalog.spec(for: name) != nil, "Нет команды \(name)") }
        for tool in NoteToolbox.tools {
            #expect(tool.name.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression) != nil)
            #expect(!tool.description.isEmpty)
        }
        #expect(Set(NoteToolbox.tools.map(\.name)).count == NoteToolbox.tools.count)
        #expect(NoteToolbox.tools == NoteToolbox.makeTools())
    }

    @Test("Схема аргументов: типы, обязательные, варианты, текст Markdown строкой")
    func schema() throws {
        let create = try tool("page_create").parameters
        #expect(create["type"] == "object")
        #expect(create["required"] == ["title"])
        #expect(create["properties"]?["title"]?["type"] == "string")
        #expect(create["properties"]?["parent"]?["type"] == "string")
        #expect(create["properties"]?["markdown"]?["type"] == "string")
        let layout = try tool("page_layout").parameters
        #expect(layout["properties"]?["fullWidth"]?["enum"] == ["on", "off"])
        let tree = try tool("page_tree").parameters
        #expect(tree["properties"]?["depth"]?["type"] == "integer")
        #expect(tree["required"] == [])
        let move = try tool("page_move").parameters
        #expect(move["properties"]?["root"]?["type"] == "boolean")
        let rows = try tool("db_row_add").parameters
        #expect(rows["properties"]?["rows"]?["type"] == "array")
    }

    @Test("Вызов: команда каталога, аргументы как есть, имя агента")
    func run() async throws {
        let commands = FakeCommands { .success($0.id, ["markdown": "# План"]) }
        let toolbox = NoteToolbox(runner: commands.runner)
        let outcome = await toolbox.run(ModelToolCall(id: "c1", name: "page_read", arguments: #"{"page":"current"}"#))
        let request = try #require(commands.seen.first)
        #expect(request.command == "page.read")
        #expect(request.args == ["page": "current"])
        #expect(request.agent == NoteToolbox.agentName)
        #expect(outcome.ok)
        #expect(outcome.output == ##"{"markdown":"# План"}"##)
    }

    @Test("JSON-аргумент, присланный строкой, разбирается; простой текст остаётся текстом")
    func jsonArguments() async throws {
        let commands = FakeCommands()
        let toolbox = NoteToolbox(runner: commands.runner)
        _ = await toolbox.run(ModelToolCall(id: "c", name: "db_row_update", arguments: #"{"database":"Задачи","row":"r","values":"{\"Статус\":\"Готово\"}"}"#))
        _ = await toolbox.run(ModelToolCall(id: "d", name: "db_cell_set", arguments: #"{"database":"Задачи","row":"r","property":"Имя","value":"Купить"}"#))
        #expect(commands.seen[0].args["values"] == ["Статус": "Готово"])
        #expect(commands.seen[1].args["value"] == "Купить")
    }

    @Test("Отказ команды — текст ошибки с подсказкой для модели")
    func failure() async {
        let commands = FakeCommands { .failure($0.id, ControlError(.pageNotFound, "Нет страницы «Х»", hint: "Посмотрите page tree")) }
        let outcome = await NoteToolbox(runner: commands.runner).run(ModelToolCall(id: "c", name: "page_read", arguments: #"{"page":"Х"}"#))
        #expect(!outcome.ok)
        #expect(outcome.output.contains("Нет страницы «Х»"))
        #expect(outcome.output.contains("Посмотрите page tree"))
    }

    @Test("Незнакомый или запрещённый инструмент и неверный JSON — ошибка без выполнения")
    func rejected() async {
        let commands = FakeCommands()
        let toolbox = NoteToolbox(runner: commands.runner)
        let forbidden = await toolbox.run(ModelToolCall(id: "a", name: "trash_empty", arguments: "{}"))
        let broken = await toolbox.run(ModelToolCall(id: "b", name: "page_read", arguments: "{page:"))
        #expect(!forbidden.ok)
        #expect(!broken.ok)
        #expect(commands.seen.isEmpty)
    }

    @Test("Длинный ответ обрезается с пометкой")
    func truncation() async {
        let long = String(repeating: "а", count: NoteToolbox.maxOutputLength * 2)
        let commands = FakeCommands { .success($0.id, ["markdown": .string(long)]) }
        let outcome = await NoteToolbox(runner: commands.runner).run(ModelToolCall(id: "c", name: "page_read", arguments: #"{"page":"x"}"#))
        #expect(outcome.output.count < NoteToolbox.maxOutputLength + 200)
        #expect(outcome.output.contains("обрезан"))
    }

    @Test("Короткая подпись вызова для ленты чата")
    func titles() {
        #expect(NoteToolbox.title(for: ModelToolCall(id: "", name: "page_read", arguments: #"{"page":"current"}"#)) == "Читает открытую страницу")
        #expect(NoteToolbox.title(for: ModelToolCall(id: "", name: "page_read", arguments: #"{"page":"Проекты/План"}"#)) == "Читает страницу «Проекты/План»")
        #expect(NoteToolbox.title(for: ModelToolCall(id: "", name: "search", arguments: #"{"query":"отпуск"}"#)) == "Ищет «отпуск»")
        #expect(NoteToolbox.title(for: ModelToolCall(id: "", name: "page_create", arguments: #"{"title":"Итоги"}"#)) == "Создаёт страницу «Итоги»")
        #expect(NoteToolbox.title(for: ModelToolCall(id: "", name: "page_trash", arguments: #"{"page":"0193a1b2-0000-7000-8000-000000000000"}"#)) == "Убирает страницу в корзину")
        #expect(!NoteToolbox.title(for: ModelToolCall(id: "", name: "db_view_update", arguments: "{}")).isEmpty)
    }
}
