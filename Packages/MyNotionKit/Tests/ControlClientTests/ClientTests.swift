import ControlProtocol
import ControlServer
import Foundation
import Synchronization
import Testing
@testable import ControlClient

final class SocketFolder {
    let url: URL

    init() {
        url = URL(fileURLWithPath: "/tmp/mc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var socketPath: String { url.appendingPathComponent("c.sock").path }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Подставной «запускатель»: считает запуски, по запуску может поднять сервер.
final class FakeLauncher: AppLaunching, @unchecked Sendable {
    let running: Bool
    let onLaunch: @Sendable () -> Void
    let launches = Mutex(0)

    init(running: Bool = false, onLaunch: @escaping @Sendable () -> Void = {}) {
        self.running = running
        self.onLaunch = onLaunch
    }

    func isAppRunning() -> Bool { running }

    func launch() throws {
        launches.withLock { $0 += 1 }
        onLaunch()
    }

    var launchCount: Int { launches.withLock { $0 } }
}

/// Ответ сервера по запросу.
typealias Reply = @Sendable (ControlRequest, AsyncStream<ControlResponseLine>.Continuation) async -> Void

func server(_ path: String, reply: @escaping Reply = { request, continuation in
    continuation.yield(.result(.success(request.id, ["command": .string(request.command)], text: "✓ Готово «\(request.command)»")))
}) -> ControlSocketServer {
    ControlSocketServer(path: path) { request in
        AsyncStream { continuation in
            Task {
                await reply(request, continuation)
                continuation.finish()
            }
        }
    }
}

final class ServerBox: @unchecked Sendable {
    let lock = NSLock()
    var server: ControlSocketServer?
    deinit { server?.stop() }
}

@Suite(.serialized) struct ClientTests {
    func settings(_ path: String, noLaunch: Bool = false, launchTimeout: Double = 2) -> ClientSettings {
        ClientSettings(noLaunch: noLaunch, launchTimeout: launchTimeout, socketPath: path)
    }

    @Test func runningAppAnswers() throws {
        let folder = SocketFolder()
        let app = server(folder.socketPath)
        try app.start()
        defer { app.stop() }
        let launcher = FakeLauncher(running: true)
        let response = CommandRunner(launcher: launcher).run(ControlRequest(id: "a", command: "app.status"), settings: settings(folder.socketPath))
        #expect(response.ok)
        #expect(response.data?["command"] == "app.status")
        #expect(launcher.launchCount == 0)
    }

    @Test func missingSocketLaunchesAppAndRetries() throws {
        let folder = SocketFolder()
        let box = ServerBox()
        let path = folder.socketPath
        let launcher = FakeLauncher {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
                let app = server(path)
                try? app.start()
                box.lock.withLock { box.server = app }
            }
        }
        let started = ContinuousClock.now
        let response = CommandRunner(launcher: launcher).run(ControlRequest(command: "app.status"), settings: settings(path))
        #expect(response.ok)
        #expect(launcher.launchCount == 1)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func appThatNeverComesUpIsNotReady() {
        let folder = SocketFolder()
        let launcher = FakeLauncher()
        let started = ContinuousClock.now
        let response = CommandRunner(launcher: launcher).run(ControlRequest(command: "app.status"),
                                                              settings: settings(folder.socketPath, launchTimeout: 0.5))
        let elapsed = ContinuousClock.now - started
        #expect(response.error?.code == .appNotReady)
        #expect(launcher.launchCount == 1)
        #expect(elapsed >= .milliseconds(450))
        #expect(elapsed < .seconds(2))
    }

    @Test func noLaunchWhenClosedIsNotRunning() {
        let folder = SocketFolder()
        let launcher = FakeLauncher()
        let response = CommandRunner(launcher: launcher).run(ControlRequest(command: "app.status"),
                                                              settings: settings(folder.socketPath, noLaunch: true))
        #expect(response.error?.code == .appNotRunning)
        #expect(ExitCode.of(response) == 5)
        #expect(launcher.launchCount == 0)
    }

    @Test func runningAppWithoutSocketIsNotReadyWithReason() {
        let folder = SocketFolder()
        let launcher = FakeLauncher(running: true)
        let response = CommandRunner(launcher: launcher).run(ControlRequest(command: "app.status"),
                                                              settings: settings(folder.socketPath, launchTimeout: 0.3))
        #expect(response.error?.code == .appNotReady)
        #expect(response.error?.details?["reason"] != nil)
        #expect(launcher.launchCount == 0)
        let noLaunch = CommandRunner(launcher: launcher).run(ControlRequest(command: "app.status"),
                                                              settings: settings(folder.socketPath, noLaunch: true))
        #expect(noLaunch.error?.code == .appNotReady)
    }

    @Test func slowAnswerTimesOut() throws {
        let folder = SocketFolder()
        let app = server(folder.socketPath) { request, continuation in
            try? await Task.sleep(for: .seconds(2))
            continuation.yield(.result(.success(request.id, true)))
        }
        try app.start()
        defer { app.stop() }
        let started = ContinuousClock.now
        let response = CommandRunner(launcher: FakeLauncher(running: true))
            .run(ControlRequest(command: "page.tree", timeoutMs: 200), settings: settings(folder.socketPath))
        #expect(response.error?.code == .timeout)
        #expect(ContinuousClock.now - started < .seconds(1.5))
    }

    @Test func appClosingMidAnswerIsDisconnected() throws {
        let folder = SocketFolder()
        let app = server(folder.socketPath) { request, continuation in
            continuation.yield(.progress(id: request.id, ControlProgress(done: 1, total: 10)))
        }
        try app.start()
        defer { app.stop() }
        var progress: [ControlProgress] = []
        let response = CommandRunner(launcher: FakeLauncher(running: true))
            .run(ControlRequest(command: "import.notion"), settings: settings(folder.socketPath)) { progress.append($0) }
        #expect(response.error?.code == .appDisconnected)
        #expect(progress == [ControlProgress(done: 1, total: 10)])
    }

    @Test func otherProtocolIsVersionMismatch() throws {
        let folder = SocketFolder()
        let app = server(folder.socketPath)
        try app.start()
        defer { app.stop() }
        let response = CommandRunner(launcher: FakeLauncher(running: true))
            .run(ControlRequest(protocol: 7, command: "app.status"), settings: settings(folder.socketPath))
        #expect(response.error?.code == .versionMismatch)
        #expect(response.error?.details == ["app": "1", "client": "7"])
        #expect(ExitCode.of(response) == 5)
    }

    @Test func bundleIsFoundFromSymlinkedExecutable() throws {
        let folder = SocketFolder()
        let helpers = folder.url.appendingPathComponent("MyNotion.app/Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let tool = helpers.appendingPathComponent("mynotion")
        try Data().write(to: tool)
        let bin = folder.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("mynotion")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)

        let bundle = SystemAppLauncher.bundleURL(forExecutable: link)
        #expect(bundle?.resolvingSymlinksInPath().path == folder.url.appendingPathComponent("MyNotion.app").resolvingSymlinksInPath().path)
        #expect(SystemAppLauncher.bundleURL(forExecutable: URL(fileURLWithPath: "/usr/bin/true")) == nil)
    }

    @Test func exitCodesFollowErrorGroup() {
        #expect(ExitCode.of(.success("", true)) == 0)
        for code in ControlErrorCode.allCases {
            #expect(ExitCode.of(.failure("", ControlError(code, "м"))) == code.group.exitCode)
        }
    }

    @Test func humanOutputPrintsMarksAndHint() throws {
        let folder = SocketFolder()
        let app = server(folder.socketPath) { request, continuation in
            if request.command == "page.get" {
                continuation.yield(.result(.failure(request.id, ControlError(.pageNotFound, "Страница «Х» не найдена",
                                                                             hint: "mynotion page tree --depth 2"))))
            } else {
                continuation.yield(.result(.success(request.id, ["page": ["id": "3f2a"]], text: request.human ? "✓ Создана «А» (3f2a)" : nil)))
            }
        }
        try app.start()
        defer { app.stop() }
        let launcher = FakeLauncher(running: true)

        var out = "", err = ""
        let ok = MyNotionCLI.run(["page", "create", "--title", "А", "--human", "--socket", folder.socketPath], launcher: launcher,
                                 out: { out += $0 }, err: { err += $0 })
        #expect(ok == 0)
        #expect(out == "✓ Создана «А» (3f2a)\n")
        #expect(err.isEmpty)

        out = ""; err = ""
        let failed = MyNotionCLI.run(["page", "get", "Х", "--human", "--socket", folder.socketPath], launcher: launcher,
                                     out: { out += $0 }, err: { err += $0 })
        #expect(failed == 3)
        #expect(out.isEmpty)
        #expect(err == "✗ Страница «Х» не найдена\n→ mynotion page tree --depth 2\n")

        out = ""; err = ""
        let json = MyNotionCLI.run(["page", "get", "Х", "--socket", folder.socketPath], launcher: launcher,
                                   out: { out += $0 }, err: { err += $0 })
        #expect(json == 3)
        let response = try ControlCoding.decoder.decode(ControlResponse.self, from: Data(out.utf8))
        #expect(response.error?.code == .pageNotFound)
    }

    @Test func usageErrorsAndHelpNeedNoApp() throws {
        let launcher = FakeLauncher { Issue.record("справка не должна запускать приложение") }
        var out = "", err = ""
        #expect(MyNotionCLI.run(["--help"], launcher: launcher, out: { out += $0 }, err: { err += $0 }) == 0)
        #expect(out.contains("Группы"))

        out = ""
        #expect(MyNotionCLI.run(["commands", "--json"], launcher: launcher, out: { out += $0 }, err: { err += $0 }) == 0)
        let catalog = try ControlJSON(parsing: out)
        #expect(catalog["data"]?["commands"]?.array?.count == CommandCatalog.all.count)

        out = ""
        #expect(MyNotionCLI.run(["page", "craete"], launcher: launcher, out: { out += $0 }, err: { err += $0 }) == 2)
        let response = try ControlCoding.decoder.decode(ControlResponse.self, from: Data(out.utf8))
        #expect(response.error?.code == .unknownCommand)
        #expect(launcher.launchCount == 0)
    }
}
