import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import NotesCore
@testable import Sync

/// Быстрые stop() и start() подряд (на iPhone — свернул и развернул): запрос старого цикла, закончившийся позже,
/// не отнимает у нового цикла ручку, которой `syncNow()` прерывает ожидание.
@MainActor
@Suite("Перезапуск цикла синхронизации")
struct SyncEngineRestartTests {
    @Test("После stop() и start() syncNow() будит новый цикл, даже когда запрос старого закончился позже")
    func syncNowWakesNewLoopAfterQuickRestart() async throws {
        let folder = try TemporaryFolder()
        let store = NotesStore(database: try AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        Outbox.install(on: store)
        let account = SyncAccount(serverURL: URL(string: "https://sync.test")!, deviceId: "iphone", deviceName: "iPhone")
        try SyncSetup.enable(store: store, account: account)
        let transport = HeldPollTransport()
        let engine = SyncEngine(store: store, account: account, transport: transport, cipher: BatchCipher(key: SymmetricKey(size: .bits256)),
                                applier: RemoteChangeApplier(store: store, openDocuments: nil, localDeviceName: "iPhone"))

        engine.start()
        try await waitUntil("первое ожидание") { transport.longPolls == 1 }
        engine.stop()
        engine.start()
        try await waitUntil("ожидание нового цикла") { transport.longPolls == 2 }

        // Запрос старого цикла отвечает только теперь, когда новый уже ждёт своего.
        transport.releaseFirstPoll()
        try await Task.sleep(for: .milliseconds(100))

        engine.syncNow()
        try await waitUntil("syncNow() прервал ожидание нового цикла") { transport.longPolls >= 3 }
        engine.stop()
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Не дождались: \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Сервер, у которого первое долгое ожидание не замечает отмены и отвечает, только когда его отпустят;
/// остальные ждут, пока их не прервут.
private final class HeldPollTransport: SyncTransport {
    private struct State {
        var longPolls = 0
        var seq = 0
        var firstPoll: CheckedContinuation<Void, Never>?
        var firstPollReleased = false
    }
    private let state = Mutex(State())

    var longPolls: Int { state.withLock { $0.longPolls } }

    func releaseFirstPoll() {
        let continuation = state.withLock { state in
            state.firstPollReleased = true
            defer { state.firstPoll = nil }
            return state.firstPoll
        }
        continuation?.resume()
    }

    func postChanges(batchId: String, ciphertext: String) async throws -> Int {
        state.withLock { state in
            state.seq += 1
            return state.seq
        }
    }

    func changes(after: Int, wait: Int) async throws -> SyncChangesPage {
        guard wait > 0 else { return SyncChangesPage(items: [], hasMore: false) }
        let number = state.withLock { state in
            state.longPolls += 1
            return state.longPolls
        }
        if number == 1 {
            await withCheckedContinuation { continuation in
                let released = state.withLock { state in
                    if !state.firstPollReleased { state.firstPoll = continuation }
                    return state.firstPollReleased
                }
                if released { continuation.resume() }
            }
        } else {
            try await Task.sleep(for: .seconds(60))
        }
        return SyncChangesPage(items: [], hasMore: false)
    }

    func ack(_ seq: Int) async throws {}
    func putSnapshot(seq: Int, ciphertext: String) async throws {}
    func snapshot() async throws -> SyncSnapshotEnvelope? { nil }
    func devices() async throws -> [SyncDevice] { [] }
    func currentDevice() async throws -> SyncDevice { SyncDevice(deviceId: "iphone", deviceName: "iPhone", lastSeenAt: nil, lastAckSeq: 0) }
    func invite() async throws -> SyncInvite { throw URLError(.unsupportedURL) }
    func deleteDevice(_ deviceId: String) async throws {}
}
