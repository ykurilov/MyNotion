import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Сервер для тестов сходимости: поддельный в памяти или настоящий из `server/` на свободном порту.
protocol SyncTestServer: Sendable {
    var server: any SyncServer { get }
    var serverURL: URL { get }
    /// Токен первого устройства (`mynotion-sync bootstrap`).
    func bootstrapToken(name: String) async throws -> String
    /// Журнал до снимка уже сжат.
    func isCompacted() async throws -> Bool
    func stop()
}

enum SyncTestServerKind: String, CustomStringConvertible, Sendable {
    case fake
    case local

    var description: String { self == .fake ? "поддельный сервер" : "сервер из server/" }

    /// Настоящий сервер — когда он есть в этой ветке и собран.
    static var available: [SyncTestServerKind] {
        #if os(macOS)
        LocalNodeSyncServer.isAvailable ? [.fake, .local] : [.fake]
        #else
        [.fake]
        #endif
    }

    func start() async throws -> any SyncTestServer {
        switch self {
        case .fake: FakeTestServer()
        case .local:
            #if os(macOS)
            try await LocalNodeSyncServer.start()
            #else
            // В симуляторе iPhone нет процессов: настоящий сервер из `server/` запускается только на Mac.
            throw URLError(.cannotConnectToHost)
            #endif
        }
    }
}

final class FakeTestServer: SyncTestServer {
    let fake = FakeSyncServer()
    var server: any SyncServer { fake }
    let serverURL = URL(string: "https://fake.sync.test")!
    func bootstrapToken(name: String) async throws -> String { try await fake.bootstrap(name: name) }
    func isCompacted() async throws -> Bool { await fake.compactedSeq > 0 }
    func stop() {}
}

/// Mac с полным циклом синхронизации: база, открытые документы, ключи в памяти, `SyncEngine`.
@MainActor
final class EngineTestMac {
    let name: String
    let folder: TemporaryFolder
    let wall: AdjustableWallClock
    let store: NotesStore
    let scheduler = ManualAutosaveScheduler()
    let documents: OpenDocuments
    let secrets = InMemorySyncSecrets()
    private(set) var engine: SyncEngine!
    private(set) var connection: SwitchableTransport!
    private(set) var account: SyncAccount!
    /// Самый новый формат пачек, который этот Mac умеет читать; меньше текущего — «старый» Mac. Задаётся до подключения.
    var supportedFormatVersion = SyncBatch.currentFormatVersion
    /// Связка ключей сервисов; `nil` — MyNotion до синхронизации ключей: они ему не передаются. Задаётся до подключения.
    var serviceKeys: InMemoryServiceKeys?
    /// Пауза перед повтором записи ключа в связку ключей.
    var keyRetryDelay: Duration = .milliseconds(50)
    /// Ключи сервисов этого запуска MyNotion; перезапуск начинает с чистой памяти.
    private var keySync: ServiceKeySync?
    private var syncServer: (any SyncServer)?

    init(name: String, wallMillis: Int64) throws {
        self.name = name
        folder = try TemporaryFolder()
        wall = AdjustableWallClock(millis: wallMillis)
        store = NotesStore(database: try AppDatabase.open(at: folder.databaseURL),
                           clock: HybridLogicalClock(deviceId: UUID(), wallClock: wall.reading))
        Outbox.install(on: store)
        documents = OpenDocuments(store: store, scheduler: scheduler)
    }

    func connectFirst(_ server: any SyncTestServer) async throws {
        try await connectFirst(server, token: try await server.bootstrapToken(name: name))
    }

    func connectFirst(_ server: any SyncTestServer, token: String) async throws {
        account = try await SyncSetup.connectFirstDevice(store: store, serverURL: server.serverURL, deviceToken: token,
                                                         deviceName: name, secrets: secrets, server: server.server)
        try makeEngine(server.server)
    }

    func join(_ server: any SyncTestServer, code: JoinCode) async throws {
        account = try await SyncSetup.join(store: store, serverURL: server.serverURL, code: code, deviceName: name,
                                           secrets: secrets, server: server.server)
        try makeEngine(server.server)
    }

    /// Выложить снимок, когда этот Mac прочёл из журнала всё, что сам отправил, — как цикл. Раньше
    /// `SyncEngine.uploadSnapshot()` молча ничего не выкладывает, и журнал не сжимается.
    func uploadSnapshot() async throws {
        let accounts = SyncAccountStore(store: store)
        try await eventually("\(name) прочёл из журнала свои пачки", within: .seconds(10)) {
            guard let account = try accounts.account() else { return false }
            return try Outbox(store: store).isEmpty() && account.lastPulledSeq >= account.lastSentSeq
        }
        try await engine.uploadSnapshot()
        let account = try #require(try accounts.account())
        #expect(account.lastSnapshotSeq == account.lastPulledSeq, "\(name) не выложил снимок")
    }

    func makeJoinCode() async throws -> JoinCode {
        try await SyncSetup.makeJoinCode(transport: connection, account: account, secrets: secrets)
    }

    /// Ключи сервисов: ввели или удалили на этом Mac.
    func saveServiceKey(_ value: String, for name: String) async throws {
        if keySync == nil { keySync = ServiceKeySync(store: store, keys: try #require(serviceKeys), retryDelay: keyRetryDelay) }
        try await try #require(keySync).save(value, for: name)
    }

    /// Обновили MyNotion до версии с синхронизацией ключей: старая не оставляла в базе ничего о ключах.
    func updateToServiceKeys(_ keys: InMemoryServiceKeys) throws {
        stop()
        try store.database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM app_meta WHERE key LIKE ?", arguments: [ServiceKeys.metaPrefix + "%"])
        }
        serviceKeys = keys
        _ = try SyncSetup.resume(store: store)
        try makeEngine(try #require(syncServer))
        start()
    }

    /// MyNotion закрыли и открыли снова: в памяти ничего не осталось, база и связка ключей — прежние.
    func restart() throws {
        stop()
        _ = try SyncSetup.resume(store: store)
        try makeEngine(try #require(syncServer))
        start()
    }

    private func makeEngine(_ server: any SyncServer) throws {
        syncServer = server
        keySync = serviceKeys.map { ServiceKeySync(store: store, keys: $0, retryDelay: keyRetryDelay) }
        let secret = try #require(try secrets.load(for: account.deviceId))
        connection = SwitchableTransport(server.transport(deviceToken: secret.deviceToken))
        engine = SyncEngine(store: store, account: account, transport: connection,
                            cipher: BatchCipher(key: secret.encryptionKey, supportedFormatVersion: supportedFormatVersion),
                            applier: RemoteChangeApplier(store: store, openDocuments: documents, localDeviceName: name, serviceKeys: keySync),
                            timing: .fastForTests)
    }

    func start() { engine.start() }
    func stop() { engine?.stop() }

    func setText(_ text: String, ofBlock blockId: UUID) throws {
        try store.write { tx in
            var block = try #require(try tx.block(blockId))
            block.text = InlineText(text)
            try tx.updateBlock(block)
        }
    }

    /// Названия всех страниц — для сравнения Mac.
    func titles() throws -> [String] {
        try store.pageOutline().map(\.title).sorted()
    }

    /// Все версии текста страницы, что есть на этом Mac: в блоках и в «Двух версиях».
    func allTextVersions(of pageId: UUID) throws -> Set<String> {
        let blocks = try store.pageContent(pageId)?.blocks.map(\.text.string) ?? []
        let conflicts = try store.unresolvedConflicts(ofPage: pageId).flatMap { [$0.localVersion.string, $0.remoteVersion.string] }
        return Set(blocks + conflicts)
    }
}

#if os(macOS)
/// Сервер из `server/` этой ветки: свой порт, своя база во временной папке; первое устройство — командой bootstrap.
final class LocalNodeSyncServer: SyncTestServer, @unchecked Sendable {
    static var serverFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server", isDirectory: true)
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: serverFolder.appendingPathComponent("dist/main.js").path)
            && nodeURL != nil
    }

    static var nodeURL: URL? {
        ["/opt/homebrew/bin/node", "/usr/local/bin/node", NSHomeDirectory() + "/.local/bin/node"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    let serverURL: URL
    var server: any SyncServer { HTTPSyncServer(url: serverURL) }
    private let process: Process
    private let dataFolder: TemporaryFolder
    private let lock = NSLock()
    private var bootstrapped: String?

    private init(serverURL: URL, process: Process, dataFolder: TemporaryFolder) {
        self.serverURL = serverURL
        self.process = process
        self.dataFolder = dataFolder
    }

    static func start() async throws -> LocalNodeSyncServer {
        let node = try #require(nodeURL)
        let dataFolder = try TemporaryFolder()
        let port = try freePort()
        let process = Process()
        process.executableURL = node
        process.arguments = [serverFolder.appendingPathComponent("dist/main.js").path]
        process.currentDirectoryURL = serverFolder
        process.environment = ["PORT": "\(port)", "DATA_DIR": dataFolder.url.path, "HOST": "127.0.0.1",
                               "PATH": "/usr/bin:/bin:" + node.deletingLastPathComponent().path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let server = LocalNodeSyncServer(serverURL: url, process: process, dataFolder: dataFolder)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let (_, response) = try? await URLSession.shared.data(from: url.appendingPathComponent("health")),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return server
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        server.stop()
        throw URLError(.cannotConnectToHost)
    }

    func bootstrapToken(name: String) async throws -> String {
        let node = try #require(Self.nodeURL)
        let process = Process()
        process.executableURL = node
        process.arguments = [Self.serverFolder.appendingPathComponent("dist/cli.js").path, "bootstrap", "--name", name, "--token-only"]
        process.currentDirectoryURL = Self.serverFolder
        process.environment = ["DATA_DIR": dataFolder.url.path, "PATH": "/usr/bin:/bin:" + node.deletingLastPathComponent().path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let token = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock { bootstrapped = token }
        return token
    }

    func isCompacted() async throws -> Bool {
        guard let token = lock.withLock({ bootstrapped }) else { return false }
        do {
            _ = try await server.transport(deviceToken: token).changes(after: 0, wait: 0)
            return false
        } catch SyncServerError.logCompacted {
            return true
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    private static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw URLError(.cannotConnectToHost) }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
#endif
