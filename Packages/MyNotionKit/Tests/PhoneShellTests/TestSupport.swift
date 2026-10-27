import CryptoKit
import Foundation
import NotesCore
import PhoneShell
import Synchronization
import Sync

/// Своя база во временной папке; папка удаляется вместе с объектом.
final class TemporaryLibrary {
    let folder: URL
    let store: NotesStore

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneShellTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
    }

    deinit { try? FileManager.default.removeItem(at: folder) }
}

/// Код подключения, который показал бы Mac.
func sampleJoinCode(invite: String = "ABCD1234") -> JoinCode {
    JoinCode(inviteCode: invite, encryptionKey: SymmetricKey(size: .bits256))
}

/// Сервер без сети: ответ на подключение задаёт тест.
final class FakeSyncServer: SyncServer {
    enum JoinOutcome: Sendable {
        case joined(deviceId: String)
        case fails(any Error)
    }

    private let state: Mutex<(outcome: JoinOutcome, joinedNames: [String], deletedDevices: [String], devices: [SyncDevice])>
    /// Список устройств не отвечает, пока тест не отпустит (`releaseDevices()`).
    private let heldDevices = Mutex<(holds: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    init(outcome: JoinOutcome = .joined(deviceId: "phone-1"), devices: [SyncDevice] = [], holdsDevices: Bool = false) {
        state = Mutex((outcome, [], [], devices))
        heldDevices.withLock { $0.holds = holdsDevices }
    }

    func releaseDevices() {
        let waiting = heldDevices.withLock { held in
            held.holds = false
            defer { held.waiting = [] }
            return held.waiting
        }
        waiting.forEach { $0.resume() }
    }

    var joinedNames: [String] { state.withLock { $0.joinedNames } }
    var deletedDevices: [String] { state.withLock { $0.deletedDevices } }

    func join(inviteCode: String, deviceName: String) async throws -> SyncJoinResult {
        let outcome = state.withLock { state in
            state.joinedNames.append(deviceName)
            return state.outcome
        }
        switch outcome {
        case .joined(let deviceId): return SyncJoinResult(deviceId: deviceId, deviceToken: "token-\(deviceId)", latestSnapshotSeq: nil)
        case .fails(let error): throw error
        }
    }

    func transport(deviceToken: String) -> any SyncTransport { FakeTransport(server: self) }

    fileprivate func devices() async -> [SyncDevice] {
        await withCheckedContinuation { continuation in
            let holds = heldDevices.withLock { held in
                if held.holds { held.waiting.append(continuation) }
                return held.holds
            }
            if !holds { continuation.resume() }
        }
        return state.withLock { $0.devices }
    }
    fileprivate func delete(_ deviceId: String) {
        state.withLock { state in
            state.deletedDevices.append(deviceId)
            state.devices.removeAll { $0.deviceId == deviceId }
        }
    }
}

private struct FakeTransport: SyncTransport {
    let server: FakeSyncServer

    func postChanges(batchId: String, ciphertext: String) async throws -> Int { 1 }
    func changes(after: Int, wait: Int) async throws -> SyncChangesPage { SyncChangesPage(items: [], hasMore: false) }
    func ack(_ seq: Int) async throws {}
    func putSnapshot(seq: Int, ciphertext: String) async throws {}
    func snapshot() async throws -> SyncSnapshotEnvelope? { nil }
    func devices() async throws -> [SyncDevice] { await server.devices() }
    func currentDevice() async throws -> SyncDevice { throw SyncServerError.notFound }
    func invite() async throws -> SyncInvite { throw SyncServerError.notFound }
    func deleteDevice(_ deviceId: String) async throws { server.delete(deviceId) }
}

/// Цикл синхронизации без сервера: тест сам решает, есть ли неотправленное.
@MainActor
final class FakeSyncLoop: PhoneSyncLoop {
    var status: SyncStatus = .ready
    var lastSyncedAt: Date?
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var syncNowCount = 0
    /// Сколько раз ещё ответить «есть неотправленное»; `nil` — всегда.
    var unsentChecksLeft: Int? = 0
    /// Круги по пушу: сколько было и не запускали ли цикл посреди круга.
    private(set) var catchUpCount = 0
    private(set) var isCatchingUp = false
    private(set) var startedWhileCatchingUp = false
    /// Что делает круг; по умолчанию ничего не приходит. Пришедшее — через `applier`, как у настоящего цикла.
    var catchUpAction: (@MainActor (RemoteChangeApplier?) async throws -> Void)?
    var applier: RemoteChangeApplier?

    func start() {
        if isCatchingUp { startedWhileCatchingUp = true }
        isRunning = true
        startCount += 1
    }

    func catchUp() async throws {
        catchUpCount += 1
        isCatchingUp = true
        defer { isCatchingUp = false }
        try await catchUpAction?(applier)
    }

    func stop() {
        isRunning = false
        stopCount += 1
    }

    func syncNow() { syncNowCount += 1 }

    func hasUnsentChanges() -> Bool {
        guard let left = unsentChecksLeft else { return true }
        guard left > 0 else { return false }
        unsentChecksLeft = left - 1
        return true
    }
}

/// Фоновое время системы: тест сам решает, когда оно кончится и даётся ли вообще.
@MainActor
final class FakeBackgroundTime: BackgroundTimeGrant {
    private(set) var begun = 0
    private(set) var ended: [BackgroundTimeToken] = []
    private var expiration: (@MainActor () -> Void)?
    var grants = true

    func begin(expiration: @escaping @MainActor () -> Void) -> BackgroundTimeToken? {
        guard grants else { return nil }
        begun += 1
        self.expiration = expiration
        return BackgroundTimeToken(rawValue: begun)
    }

    func end(_ token: BackgroundTimeToken) { ended.append(token) }

    func expire() { expiration?() }

    var isHeld: Bool { begun > ended.count }
}

/// Часы пауз: пауза не ждёт, а только считает время.
final class FakePauses: Sendable {
    private let total = Mutex<Duration>(.zero)

    var elapsed: Duration { total.withLock { $0 } }

    var pause: @Sendable (Duration) async -> Void {
        { [self] duration in
            total.withLock { $0 += duration }
            await Task.yield()
        }
    }
}

/// Подождать, пока условие станет верным (задачи контроллера идут своим ходом).
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

/// Связка ключей, которая может не ответить: до первой разблокировки iPhone или при сбое удаления.
final class UnreliableSecrets: SyncSecrets {
    struct Unavailable: Error {}
    private let stored = InMemorySyncSecrets()
    private let failures = Mutex<(load: Bool, delete: Bool)>((false, false))

    var loadFails: Bool {
        get { failures.withLock { $0.load } }
        set { failures.withLock { $0.load = newValue } }
    }
    var deleteFails: Bool {
        get { failures.withLock { $0.delete } }
        set { failures.withLock { $0.delete = newValue } }
    }

    func save(_ values: SyncSecretValues, for deviceId: String) throws { try stored.save(values, for: deviceId) }

    func load(for deviceId: String) throws -> SyncSecretValues? {
        if loadFails { throw Unavailable() }
        return try stored.load(for: deviceId)
    }

    func delete(for deviceId: String) throws {
        if deleteFails { throw Unavailable() }
        try stored.delete(for: deviceId)
    }

    /// Что лежит на самом деле, мимо сбоев.
    func storedValues(for deviceId: String) throws -> SyncSecretValues? { try stored.load(for: deviceId) }
}

/// Сервер, которому iPhone сообщает токен пушей: запоминает, что пришло; может не принять.
final class FakePushServer: Sendable {
    struct Registration: Hashable {
        let deviceToken: String
        let apnsToken: Data
        let environment: SyncPushEnvironment
    }

    private let state = Mutex<(registrations: [Registration], fails: Bool)>(([], false))

    var registrations: [Registration] { state.withLock { $0.registrations } }
    var fails: Bool {
        get { state.withLock { $0.fails } }
        set { state.withLock { $0.fails = newValue } }
    }

    func transport(deviceToken: String) -> any SyncPushTransport { Bound(owner: self, deviceToken: deviceToken) }

    fileprivate func register(_ registration: Registration) throws {
        try state.withLock { state in
            if state.fails { throw URLError(.notConnectedToInternet) }
            state.registrations.append(registration)
        }
    }

    private struct Bound: SyncPushTransport {
        let owner: FakePushServer
        let deviceToken: String

        func registerPushToken(_ token: Data, environment: SyncPushEnvironment) async throws {
            try owner.register(Registration(deviceToken: deviceToken, apnsToken: token, environment: environment))
        }
    }
}
