import ControlProtocol
import Foundation
import Testing
@testable import ControlCommands
@testable import NotesCore

/// Порядок событий подставных обработчиков.
@MainActor final class EventLog {
    var events: [String] = []
}

@MainActor @Suite struct ExecutorTests {
    let host: TestHost
    let log = RecordingLog()

    init() throws {
        host = try TestHost()
    }

    func executor(_ handlers: [String: CommandHandler]) -> CommandExecutor {
        CommandExecutor(host: host, registry: HandlerRegistry(handlers), log: log)
    }

    @Test func unknownCommand() async {
        let response = await executor([:]).run(ControlRequest(command: "page.fly"))
        #expect(response.error?.code == .unknownCommand)
        #expect(response.error?.details?["suggestion"] != nil)
    }

    @Test func commandWithoutHandlerIsNotImplemented() async {
        let response = await executor([:]).run(ControlRequest(command: "page.tree"))
        #expect(response.error?.code == .notImplemented)
        #expect(response.error?.details?["stage"] == 2)
        #expect(response.error?.message.contains("этап 2") == true)
    }

    @Test func standardRegistryLeavesLaterStagesNotImplemented() async {
        let executor = CommandExecutor(host: host, log: log)
        #expect(await executor.run(ControlRequest(command: "page.tree")).error?.code == .notImplemented)
        let status = await executor.run(ControlRequest(command: "app.status"))
        #expect(status.ok)
        #expect(status.data?["protocol"] == 1)
        #expect(status.data?["database"] == .string(host.folder.databaseURL.path))
    }

    @Test func argumentsAreCheckedBeforeHandler() async {
        let events = EventLog()
        let response = await executor(["page.move": { _ in
            events.events.append("ran")
            return CommandResult()
        }]).run(ControlRequest(command: "page.move", args: ["root": true]))
        #expect(response.error?.code == .missingArgument)
        #expect(events.events.isEmpty)
    }

    @Test func writesRunOneAtATime() async {
        let events = EventLog()
        let slowWrite: CommandHandler = { session in
            let title = session.string("title") ?? ""
            events.events.append("start \(title)")
            try await Task.sleep(for: .milliseconds(80))
            events.events.append("end \(title)")
            return CommandResult()
        }
        let executor = executor(["page.rename": slowWrite])
        async let first = executor.run(ControlRequest(command: "page.rename", args: ["page": "x", "title": "1"]))
        async let second = executor.run(ControlRequest(command: "page.rename", args: ["page": "x", "title": "2"]))
        _ = await (first, second)
        #expect(events.events.count == 4)
        #expect(events.events[0].hasPrefix("start") && events.events[1].hasPrefix("end"))
        #expect(events.events[2].hasPrefix("start") && events.events[3].hasPrefix("end"))
    }

    @Test func readDoesNotWaitForWrite() async {
        let events = EventLog()
        let executor = executor([
            "page.rename": { _ in
                events.events.append("write start")
                try await Task.sleep(for: .milliseconds(300))
                events.events.append("write end")
                return CommandResult()
            },
            "page.get": { _ in
                events.events.append("read")
                return CommandResult()
            },
        ])
        async let write = executor.run(ControlRequest(command: "page.rename", args: ["page": "x", "title": "1"]))
        try? await Task.sleep(for: .milliseconds(30))
        let read = await executor.run(ControlRequest(command: "page.get", args: ["page": "x"]))
        #expect(read.ok)
        #expect(events.events == ["write start", "read"])
        _ = await write
    }

    @Test func handlerErrorsBecomeResponses() async {
        let executor = executor([
            "page.get": { session in CommandResult(["page": .string(try session.page().title)]) },
            "page.rename": { _ in throw CocoaError(.fileWriteNoPermission) },
        ])
        #expect(await executor.run(ControlRequest(command: "page.get", args: ["page": "Нет такой"])).error?.code == .pageNotFound)
        #expect(await executor.run(ControlRequest(command: "page.rename", args: ["page": "x", "title": "1"])).error?.code == .internal)
    }

    @Test func oneLogLineWithoutContent() async {
        let executor = executor(["page.write": { _ in CommandResult() }])
        _ = await executor.run(ControlRequest(command: "page.write", args: ["page": "x", "markdown": "секретный текст"], agent: "codex"))
        _ = await executor.run(ControlRequest(command: "page.fly"))
        #expect(log.entries.count == 2)
        let entry = log.entries[0]
        #expect(entry.command == "page.write")
        #expect(entry.agent == "codex")
        #expect(entry.errorCode == nil)
        #expect(!entry.line.contains("секретный"))
        #expect(entry.line.contains("page.write"))
        #expect(log.entries[1].errorCode == .unknownCommand)
    }

    @Test func listsArePaged() async {
        let executor = executor(["page.tree": { session in
            CommandResult(try session.paged((0..<250).map { ControlJSON.number(Double($0)) }))
        }])
        let first = await executor.run(ControlRequest(command: "page.tree"))
        #expect(first.data?["items"]?.array?.count == 200)
        let cursor = first.data?["nextCursor"]
        #expect(cursor?.string != nil)
        let second = await executor.run(ControlRequest(command: "page.tree", args: ["cursor": cursor!]))
        #expect(second.data?["items"]?.array?.count == 50)
        #expect(second.data?["items"]?[0] == 200)
        #expect(second.data?["nextCursor"] == .null)
        let small = await executor.run(ControlRequest(command: "page.tree", args: ["limit": 10]))
        #expect(small.data?["items"]?.array?.count == 10)
        #expect(await executor.run(ControlRequest(command: "page.tree", args: ["limit": 1001])).error?.code == .invalidArgument)
        #expect(await executor.run(ControlRequest(command: "page.tree", args: ["cursor": "мусор"])).error?.code == .invalidValue)
    }

    @Test func warningsAndProgressReachResponse() async {
        let executor = executor(["page.write": { session in
            session.report(ControlProgress(done: 1, total: 2, stage: "блоки"))
            session.warn(.markdownUnsupported, "HTML стал абзацем", line: 3)
            return CommandResult(["ok": true], text: "Записано")
        }])
        var progress: [ControlProgress] = []
        let response = await executor.run(ControlRequest(command: "page.write", args: ["page": "x", "markdown": "a"])) { progress.append($0) }
        #expect(progress == [ControlProgress(done: 1, total: 2, stage: "блоки")])
        #expect(response.warnings == [ControlWarning(.markdownUnsupported, "HTML стал абзацем", line: 3)])
        #expect(response.text == "Записано")
    }

    @Test func streamEndsWithResult() async {
        let executor = executor(["page.write": { session in
            session.report(ControlProgress(done: 1))
            return CommandResult()
        }])
        var lines: [ControlResponseLine] = []
        for await line in executor.stream(ControlRequest(id: "r1", command: "page.write", args: ["page": "x", "markdown": "a"])) {
            lines.append(line)
        }
        #expect(lines.count == 2)
        #expect(lines.last?.isFinal == true)
        if case .result(let response) = lines.last { #expect(response.id == "r1") }
    }

    @Test func writeIsOneUndoStep() async throws {
        let parent = try host.page("Корень")
        let executor = executor(["page.create": { session in
            let page = try session.pageTree.createSubpage(in: parent.id, title: "А")
            try session.pageTree.rename(page.id, to: "Б")
            return CommandResult(["id": .string(page.id.uuidString.lowercased())])
        }])
        let response = await executor.run(ControlRequest(command: "page.create", args: ["title": "А"]))
        #expect(response.ok, "\(String(describing: response.error))")
        #expect(executor.lastUndoManager?.canUndo == true)
        executor.lastUndoManager?.undo()
        #expect(executor.lastUndoManager?.canUndo == false)
    }
}
