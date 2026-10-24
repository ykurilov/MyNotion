import Foundation
import Testing
@testable import ControlProtocol

@Suite struct ArgumentParserTests {
    func request(_ argv: [String], environment: [String: String] = [:],
                 files: [String: String] = [:]) throws(ControlError) -> (ControlRequest, ClientSettings) {
        let invocation = try CommandCatalog.parse(argv, environment: environment, currentDirectory: "/tmp/work") { path in
            guard let text = files[path] else { throw CocoaError(.fileNoSuchFile) }
            return text
        }
        guard case .request(let request, let settings, _) = invocation else {
            throw ControlError(.internal, "не запрос: \(invocation)")
        }
        return (request, settings)
    }

    func failure(_ argv: [String], files: [String: String] = [:]) -> ControlError? {
        do {
            _ = try request(argv, files: files)
            return nil
        } catch {
            return error
        }
    }

    @Test func positionalsAndFlags() throws {
        let (request, settings) = try request(["page", "rename", "Проекты/Встреча", "--title", "Встреча 24.10"])
        #expect(request.command == "page.rename")
        #expect(request.args == ["page": "Проекты/Встреча", "title": "Встреча 24.10"])
        #expect(request.cwd == "/tmp/work")
        #expect(request.agent == "агент")
        #expect(request.timeoutMs == 30_000)
        #expect(settings == ClientSettings())
    }

    @Test func flagWithEqualsSign() throws {
        let (request, _) = try request(["page", "create", "--title=А=Б", "--parent=Проекты"])
        #expect(request.args["title"] == "А=Б")
        #expect(request.args["parent"] == "Проекты")
    }

    @Test func repeatedFlagCollectsValues() throws {
        let (request, _) = try request(["db", "relation", "link", "Задачи", "Купить", "Проект", "--to", "a1", "a2", "--to", "a3"])
        #expect(request.args["to"] == ["a1", "a2", "a3"])
        let (rows, _) = try self.request(["db", "row", "trash", "Задачи", "r1", "r2", "r3"])
        #expect(rows.args["rows"] == ["r1", "r2", "r3"])
    }

    @Test func nonRepeatedFlagTwiceFails() {
        let error = failure(["page", "rename", "А", "--title", "Б", "--title", "В"])
        #expect(error?.code == .invalidArgument)
    }

    @Test func dashReadsStdin() throws {
        let (request, _) = try request(["page", "write", "А", "--markdown", "-"], files: ["-": "# Привет\n"])
        #expect(request.args["markdown"] == "# Привет\n")
        let (file, _) = try self.request(["page", "append", "А", "--markdown", "note.md"], files: ["note.md": "текст"])
        #expect(file.args["markdown"] == "текст")
    }

    @Test func batchReadsStdinByDefault() throws {
        let steps = #"[{"command":"page.create","args":{"title":"А"}}]"#
        let (request, _) = try request(["batch"], files: ["-": steps])
        #expect(request.args["steps"]?[0]?["command"] == "page.create")
    }

    @Test func missingFileIsReported() {
        #expect(failure(["page", "write", "А", "--markdown", "нет.md"])?.code == .fileNotFound)
    }

    @Test func unknownFlagSuggestsNearest() {
        let error = failure(["page", "create", "--titel", "А"])
        #expect(error?.code == .invalidArgument)
        #expect(error?.details?["suggestion"] == "--title")
        #expect(error?.hint?.contains("--title") == true)
    }

    @Test func unknownCommandSuggestsNearest() {
        let error = failure(["page", "craete", "--title", "А"])
        #expect(error?.code == .unknownCommand)
        #expect(error?.details?["suggestion"] == "page create")
        #expect(failure(["зелёный"])?.code == .unknownCommand)
    }

    @Test func missingRequired() {
        let error = failure(["page", "create"])
        #expect(error?.code == .missingArgument)
        #expect(error?.details?["argument"] == "title")
        #expect(failure(["page", "rename", "--title", "Б"])?.code == .missingArgument)
    }

    @Test func mutuallyExclusive() {
        let error = failure(["page", "move", "А", "--parent", "Б", "--after", "В", "--first"])
        #expect(error?.code == .invalidArgument)
        #expect(error?.details?["conflicting"] == ["after", "first"])
        #expect(failure(["page", "move", "А"])?.code == .missingArgument)
    }

    @Test func valueTypesAreChecked() {
        let depth = failure(["page", "tree", "--depth", "много"])
        #expect(depth?.code == .invalidValue)
        #expect(depth?.details?["expected"] == "целое число")
        let choice = failure(["page", "read", "А", "--format", "html"])
        #expect(choice?.code == .invalidValue)
        #expect(choice?.details?["allowed"] == ["markdown", "json"])
        #expect(failure(["block", "update", "b", "--props", "{не json"])?.code == .invalidValue)
    }

    @Test func extraPositionalFails() {
        #expect(failure(["page", "get", "А", "Б"])?.code == .invalidArgument)
    }

    @Test func defaultsAreFilled() throws {
        let (request, _) = try request(["page", "read", "А"])
        #expect(request.args["format"] == "markdown")
    }

    @Test func globalFlagsAnywhere() throws {
        let (request, settings) = try request(
            ["--human", "page", "tree", "--limit", "50", "--agent", "Codex", "--include-trashed", "--cursor", "c1",
             "--timeout", "5000", "--no-launch", "--launch-timeout", "3", "--socket", "/tmp/s.sock"])
        #expect(request.human)
        #expect(request.agent == "Codex")
        #expect(request.timeoutMs == 5_000)
        #expect(request.args["limit"] == 50)
        #expect(request.args["includeTrashed"] == true)
        #expect(request.args["cursor"] == "c1")
        #expect(settings == ClientSettings(human: true, noLaunch: true, launchTimeout: 3, socketPath: "/tmp/s.sock"))
    }

    @Test func environmentGivesAgentAndSocket() throws {
        let (request, settings) = try request(["app", "status"], environment: ["MYNOTION_AGENT": "Claude", "MYNOTION_SOCKET": "/tmp/x.sock"])
        #expect(request.agent == "Claude")
        #expect(settings.socketPath == "/tmp/x.sock")
        let (flagged, _) = try self.request(["app", "status", "--agent", "Codex"], environment: ["MYNOTION_AGENT": "Claude"])
        #expect(flagged.agent == "Codex")
    }

    @Test func longCommandsGetLongTimeout() throws {
        let (request, _) = try request(["import", "notion", "export.zip"])
        #expect(request.timeoutMs == 600_000)
    }

    @Test func limitOutOfRange() {
        #expect(failure(["page", "tree", "--limit", "1001"])?.code == .invalidArgument)
        #expect(failure(["page", "tree", "--limit", "0"])?.code == .invalidArgument)
    }

    @Test func helpOnThreeLevels() throws {
        guard case .help(let top) = try CommandCatalog.parse(["--help"]) else { Issue.record("нет справки"); return }
        #expect(top.contains("db"))
        #expect(top.contains("--human"))
        guard case .help(let empty) = try CommandCatalog.parse([]) else { Issue.record("нет справки"); return }
        #expect(empty == top)

        guard case .help(let group) = try CommandCatalog.parse(["db", "--help"]) else { Issue.record("нет справки"); return }
        #expect(group.contains("db prop add"))
        #expect(!group.contains("page create"))
        guard case .help(let bare) = try CommandCatalog.parse(["db", "prop"]) else { Issue.record("нет справки"); return }
        #expect(bare.contains("db prop add"))
        #expect(!bare.contains("db row add"))

        guard case .help(let command) = try CommandCatalog.parse(["page", "move", "--help"]) else { Issue.record("нет справки"); return }
        #expect(command.contains("--parent"))
        #expect(command.contains("Пример"))
        #expect(command.contains("Не вместе"))
        guard case .help = try CommandCatalog.parse(["page", "create", "-h"]) else { Issue.record("нет справки"); return }
    }

    @Test func versionFlag() throws {
        guard case .version = try CommandCatalog.parse(["--version"]) else { Issue.record("нет версии"); return }
    }

    @Test func requestValidationInApp() {
        // Приложение проверяет тот же каталог: запрос, собранный руками, проходит те же правила.
        let spec = CommandCatalog.spec(for: "page.create")!
        #expect(throws: ControlError.self) { try CommandCatalog.normalized(["title": "А", "colour": "red"], for: spec) }
        #expect(throws: ControlError.self) { try CommandCatalog.normalized(["title": 5], for: spec) }
        #expect((try? CommandCatalog.normalized(["title": "А"], for: spec)) == ["title": "А"])
    }
}
