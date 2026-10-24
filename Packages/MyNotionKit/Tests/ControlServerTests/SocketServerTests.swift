import ControlProtocol
import Darwin
import Foundation
import Testing
@testable import ControlServer

/// Чужой пользователь у каждого подключения.
struct StrangerCredentials: PeerCredentials {
    func userID(ofPeer socket: Int32) -> uid_t? { getuid() + 1 }
}

/// Сервер-эхо: в ответ — имя команды и аргументы.
func echoServer(_ path: String, credentials: any PeerCredentials = KernelPeerCredentials(),
                delay: Duration = .zero) -> ControlSocketServer {
    ControlSocketServer(path: path, credentials: credentials) { request in
        AsyncStream { continuation in
            Task {
                if delay > .zero { try? await Task.sleep(for: delay) }
                continuation.yield(.progress(id: request.id, ControlProgress(done: 1, total: 2)))
                continuation.yield(.result(.success(request.id, ["command": .string(request.command), "args": .object(request.args)])))
                continuation.finish()
            }
        }
    }
}

@Suite(.serialized) struct SocketServerTests {
    @Test func socketFileIsOwnerOnly() throws {
        let folder = SocketFolder()
        let server = echoServer(folder.socketPath)
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.socketPath)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(attributes[.type] as? FileAttributeType == .typeSocket)
    }

    @Test func requestGetsProgressAndResult() throws {
        let folder = SocketFolder()
        let server = echoServer(folder.socketPath)
        try server.start()
        defer { server.stop() }
        let lines = try RawClient.exchange(ControlRequest(id: "r1", command: "app.status", args: ["x": 1]), path: folder.socketPath)
        #expect(lines == [.progress(id: "r1", ControlProgress(done: 1, total: 2)),
                          .result(.success("r1", ["command": "app.status", "args": ["x": 1]]))])
    }

    @Test func strangerIsClosedWithoutAnswer() throws {
        let folder = SocketFolder()
        let server = echoServer(folder.socketPath, credentials: StrangerCredentials())
        try server.start()
        defer { server.stop() }
        #expect(try RawClient.exchange(ControlRequest(command: "app.status"), path: folder.socketPath).isEmpty)
    }

    @Test func otherProtocolVersionIsRefused() throws {
        let folder = SocketFolder()
        let server = echoServer(folder.socketPath)
        try server.start()
        defer { server.stop() }
        let lines = try RawClient.exchange(ControlRequest(protocol: 2, id: "v", command: "app.status"), path: folder.socketPath)
        guard case .result(let response) = lines.last else { Issue.record("нет ответа"); return }
        #expect(response.error?.code == .versionMismatch)
        #expect(response.error?.details == ["app": "1", "client": "2"])
    }

    @Test func brokenJSONGetsError() throws {
        let folder = SocketFolder()
        let server = echoServer(folder.socketPath)
        try server.start()
        defer { server.stop() }
        let fd = try #require(RawClient.connect(folder.socketPath))
        defer { close(fd) }
        RawClient.write(Data("{не json\n".utf8), to: fd)
        let lines = RawClient.readLines(fd)
        let response = try LineFraming.decode(ControlResponse.self, from: Data(try #require(lines.last).utf8))
        #expect(response.error?.code == .invalidArgument)
    }

    @Test func staleSocketFileIsReplaced() throws {
        let folder = SocketFolder()
        // Файл остался от упавшего приложения: сокет есть, никто не слушает.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in folder.socketPath.utf8.enumerated() { buffer[index] = byte }
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(stale)
        #expect(FileManager.default.fileExists(atPath: folder.socketPath))

        let server = echoServer(folder.socketPath)
        try server.start()
        defer { server.stop() }
        #expect(try RawClient.exchange(ControlRequest(command: "app.status"), path: folder.socketPath).count == 2)
    }

    @Test func liveSocketOfOtherCopyIsLeftAlone() throws {
        let folder = SocketFolder()
        let first = echoServer(folder.socketPath)
        try first.start()
        defer { first.stop() }
        let second = echoServer(folder.socketPath)
        #expect(throws: ControlSocketServer.StartFailure.otherInstanceRunning) { try second.start() }
        #expect(try RawClient.exchange(ControlRequest(command: "app.status"), path: folder.socketPath).count == 2)
    }

    @Test func twentyClientsAtOnceGetTheirOwnAnswers() async throws {
        let folder = SocketFolder()
        let server = echoServer(folder.socketPath, delay: .milliseconds(50))
        try server.start()
        defer { server.stop() }
        let path = folder.socketPath
        // Клиенты читают блокирующе — на потоках GCD: в общем пуле задач они заняли бы все потоки, и ответам
        // сервера (они идут задачами) стало бы негде выполняться.
        let answers = await withCheckedContinuation { (continuation: CheckedContinuation<[Int: ControlResponseLine], Never>) in
            let group = DispatchGroup()
            let lock = NSLock()
            nonisolated(unsafe) var result: [Int: ControlResponseLine] = [:]
            for index in 0..<20 {
                DispatchQueue.global().async(group: group) {
                    let request = ControlRequest(id: "r\(index)", command: "page.get", args: ["n": .number(Double(index))])
                    guard let line = try? RawClient.exchange(request, path: path).last else { return }
                    lock.withLock { result[index] = line }
                }
            }
            group.notify(queue: .global()) { continuation.resume(returning: lock.withLock { result }) }
        }
        #expect(answers.count == 20)
        for (index, line) in answers {
            #expect(line == .result(.success("r\(index)", ["command": "page.get", "args": ["n": .number(Double(index))]])))
        }
    }

    @Test func clientLeavingMidCommandDoesNotStopServer() async throws {
        let folder = SocketFolder()
        let finished = Finished()
        let server = ControlSocketServer(path: folder.socketPath) { request in
            AsyncStream { continuation in
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    for index in 0..<50 { continuation.yield(.progress(id: request.id, ControlProgress(done: index))) }
                    continuation.yield(.result(.success(request.id, true)))
                    await finished.mark()
                    continuation.finish()
                }
            }
        }
        try server.start()
        defer { server.stop() }
        let fd = try #require(RawClient.connect(folder.socketPath))
        RawClient.write(try LineFraming.frame(ControlRequest(command: "import.notion")), to: fd)
        close(fd)
        // Команда доводится до конца, сервер жив и отвечает дальше.
        for _ in 0..<50 where await !finished.value { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await finished.value)
        #expect(try RawClient.exchange(ControlRequest(command: "app.status"), path: folder.socketPath).last != nil)
    }

    @Test func stopRemovesSocketFile() throws {
        let folder = SocketFolder()
        let server = echoServer(folder.socketPath)
        try server.start()
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: folder.socketPath))
        #expect(RawClient.connect(folder.socketPath) == nil)
    }

    @Test func socketPathFallsBackToTemporaryFolder() {
        let short = ControlSocketPath.path(forDatabaseFolder: URL(fileURLWithPath: "/Users/u/Library/Application Support/MyNotion"))
        #expect(short == "/Users/u/Library/Application Support/MyNotion/control.sock")
        let deep = URL(fileURLWithPath: "/tmp/" + String(repeating: "очень-длинная-папка/", count: 6))
        let long = ControlSocketPath.path(forDatabaseFolder: deep, temporaryDirectory: "/tmp/t/")
        #expect(long.hasPrefix("/tmp/t/mynotion-"))
        #expect(long.hasSuffix(".sock"))
        #expect(long.count == "/tmp/t/mynotion-12345678.sock".count)
        #expect(long == ControlSocketPath.path(forDatabaseFolder: deep, temporaryDirectory: "/tmp/t/"))
    }
}

actor Finished {
    private(set) var value = false
    func mark() { value = true }
}
