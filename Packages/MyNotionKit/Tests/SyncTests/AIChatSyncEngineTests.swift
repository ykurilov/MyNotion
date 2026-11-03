import CryptoKit
import Foundation
import GRDB
import Testing
@testable import AIChatHistory
@testable import NotesCore
@testable import Sync

/// Чаты ИИ-агента между устройствами (008): едут отдельной пачкой после записей, внутри того же шифрования;
/// MyNotion без чатов пропускает поле; новое устройство получает их из журнала или снимка; устройство, которое
/// могло пропустить чаты, просит другие прислать свои.
@MainActor
@Suite("Чаты ИИ-агента через синхронизацию", .serialized)
struct AIChatSyncEngineTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Чат с Mac A появляется на Mac B с сообщениями и названием; новое сообщение доходит следом")
    func chatTravels() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }
        let aChats = AIChatStore(store: a.store)
        let bChats = AIChatStore(store: b.store)

        let chat = try aChats.createChat(title: "Новый чат", at: date)
        try aChats.append(#"{"kind":"user","text":"Привет"}"#, id: UUID(), to: chat.id, at: date)
        try aChats.rename(chat.id, to: "Приветствие")
        try await eventually("чат дошёл до B", within: .seconds(10)) {
            try bChats.chat(chat.id)?.title == "Приветствие" && bChats.messages(in: chat.id).count == 1
        }

        try aChats.append(#"{"kind":"assistant","text":"Здравствуйте"}"#, id: UUID(), to: chat.id, at: date.addingTimeInterval(3))
        try await eventually("второе сообщение дошло", within: .seconds(10)) { try bChats.messages(in: chat.id).count == 2 }
        #expect(try bChats.chat(chat.id)?.updatedAt == date.addingTimeInterval(3))
        try await eventually("обе стороны готовы", within: .seconds(10)) {
            try a.engine.status == .ready && b.engine.status == .ready && !AIChatSync.hasPending(in: a.store)
        }
    }

    @Test("Новое устройство после сжатия журнала получает чаты из снимка")
    func snapshotCarriesChats() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }
        let chat = try AIChatStore(store: a.store).createChat(title: "Из снимка", at: date)
        try AIChatStore(store: a.store).append("m", id: UUID(), to: chat.id, at: date)
        try await eventually("чат дошёл до B", within: .seconds(10)) { try AIChatStore(store: b.store).messages(in: chat.id).count == 1 }
        try await a.uploadSnapshot()
        try await eventually("журнал сжат", within: .seconds(10)) { try await server.isCompacted() }

        let c = try EngineTestMac(name: "Mac C", wallMillis: 30_000)
        defer { c.stop() }
        try await c.join(server, code: a.makeJoinCode())
        c.start()
        try await eventually("C получил чат", within: .seconds(10)) { try AIChatStore(store: c.store).messages(in: chat.id).map(\.body) == ["m"] }
    }

    @Test("Mac, обновившийся со старой версии, просит чаты и получает пропущенные")
    func updatedDeviceRequestsChats() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }
        let chat = try AIChatStore(store: a.store).createChat(title: "Пропущенный", at: date)
        try AIChatStore(store: a.store).append("m", id: UUID(), to: chat.id, at: date)
        try await eventually("чат дошёл до B", within: .seconds(10)) { try AIChatStore(store: b.store).messages(in: chat.id).count == 1 }

        // Старая версия пропустила поле с чатами и ничего о них не знала.
        b.stop()
        try await b.store.database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM ai_chat; DELETE FROM app_meta WHERE key LIKE 'sync.aiChats.%'")
        }
        try b.restart()
        try await eventually("B получил чат снова", within: .seconds(10)) { try AIChatStore(store: b.store).messages(in: chat.id).count == 1 }
    }

    @Test("Снимок старой версии без чатов: устройство просит другие прислать их")
    func oldSnapshotRequestsChats() throws {
        let b = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
        try b.store.write { tx in
            try SyncAccountStore.save(SyncAccount(serverURL: URL(string: "https://fake.sync.test")!, deviceId: "b", deviceName: "Mac B"),
                                      in: tx.database)
        }
        let applier = RemoteChangeApplier(store: b.store, openDocuments: nil, localDeviceName: "Mac B")
        try applier.apply(SyncSnapshot(seq: 3, changes: [], knowledge: ClockKnowledge()))
        #expect(try AIChatSync.pending(in: b.store)?.request != nil)
    }

    @Test("Снимок с частью чатов: устройство просит другие прислать остальные; полный снимок — не просит")
    func partialSnapshotRequestsChats() throws {
        for partial in [true, false] {
            let b = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
            try b.store.write { tx in
                try SyncAccountStore.save(SyncAccount(serverURL: URL(string: "https://fake.sync.test")!, deviceId: "b", deviceName: "Mac B"),
                                          in: tx.database)
            }
            let applier = RemoteChangeApplier(store: b.store, openDocuments: nil, localDeviceName: "Mac B")
            try applier.apply(SyncSnapshot(seq: 3, changes: [], knowledge: ClockKnowledge(), aiChats: [], aiChatsPartial: partial ? true : nil))
            #expect((try AIChatSync.pending(in: b.store)?.request != nil) == partial)
        }
    }

    @Test("Снимок новой версии несёт чаты, даже пустой список")
    func snapshotAlwaysHasChats() throws {
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        #expect(try SyncSnapshot.make(seq: 1, from: a.store).aiChats == [])
        let chat = try AIChatStore(store: a.store).createChat(title: "Т", at: date)
        #expect(try SyncSnapshot.make(seq: 2, from: a.store).aiChats?.map(\.id) == [chat.id])
    }

    @Test("Пачка с чатами проходит шифрование; пачка без поля читается как прежде")
    func batchCoding() throws {
        let cipher = BatchCipher(key: SymmetricKey(size: .bits256))
        let record = AIChatSyncRecord(id: UUID(), title: "Т", createdAt: date, updatedAt: date, deletedAt: nil,
                                      clock: HybridTimestamp(wallMillis: 5, counter: 0, deviceId: UUID()),
                                      messages: [.init(id: UUID(), position: 0, createdAt: date, body: #"{"kind":"user"}"#)])
        let batch = SyncBatch(deviceId: "d", deviceName: "Mac", changes: [], aiChats: [record], requestsAIChats: true)
        let opened = try cipher.open(try cipher.seal(batch, batchId: "b1"), batchId: "b1", deviceId: "d")
        #expect(opened.aiChats == [record])
        #expect(opened.requestsAIChats == true)

        let old = try cipher.open(try cipher.seal(SyncBatch(deviceId: "d", deviceName: "Mac", changes: []), batchId: "b2"), batchId: "b2", deviceId: "d")
        #expect(old.aiChats == nil && old.requestsAIChats == nil)
    }

    @Test("Ключ OpenRouter ездит как остальные ключи сервисов")
    func openRouterKeyTravels() async throws {
        #expect(ServiceKeyName.all.contains(ServiceKeyName.openRouter))
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server, keys: true)
        defer { a.stop(); b.stop() }
        try await a.saveServiceKey("sk-or-test", for: ServiceKeyName.openRouter)
        try await eventually("ключ дошёл до B", within: .seconds(10)) { try b.serviceKeys?.value(for: ServiceKeyName.openRouter) == "sk-or-test" }
    }

    private func connectedPair(_ server: any SyncTestServer, keys: Bool = false) async throws -> (EngineTestMac, EngineTestMac) {
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        if keys { a.serviceKeys = InMemoryServiceKeys() }
        try await a.connectFirst(server)
        let b = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
        if keys { b.serviceKeys = InMemoryServiceKeys() }
        try await b.join(server, code: a.makeJoinCode())
        a.start()
        b.start()
        return (a, b)
    }
}
