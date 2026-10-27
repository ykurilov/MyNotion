import Foundation
import GRDB
import Testing
@testable import NotesCore
@testable import Sync

/// Ключи DeepSeek и Notion между устройствами (ключи сервисов): ездят только внутри зашифрованных пачек и снимков,
/// на устройстве — только в связке ключей; две правки сходятся по меткам часов; MyNotion без синхронизации ключей
/// пропускает их и синхронизирует остальное, а после обновления получает ключи сам.
@MainActor
@Suite("Ключи сервисов через синхронизацию", .serialized)
struct ServiceKeySyncTests {
    let deepSeek = ServiceKeyName.deepSeek
    let notion = ServiceKeyName.notion

    @Test("Ввёл, поменял и удалил ключ на одном Mac — так же становится на другом")
    func keyFollowsEditsAndRemoval() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        try await a.saveServiceKey("sk-first", for: deepSeek)
        try await a.saveServiceKey("ntn_first", for: notion)
        try await eventually("ключи дошли до B", within: .seconds(10)) {
            try b.serviceKeys?.value(for: deepSeek) == "sk-first" && b.serviceKeys?.value(for: notion) == "ntn_first"
        }

        try await a.saveServiceKey("  sk-second\n", for: deepSeek)
        try await eventually("новый ключ дошёл до B", within: .seconds(10)) { try b.serviceKeys?.value(for: deepSeek) == "sk-second" }

        try await b.saveServiceKey("", for: notion)
        try await eventually("удаление дошло до A", within: .seconds(10)) { try a.serviceKeys?.value(for: notion) == nil }
        #expect(try a.serviceKeys?.value(for: deepSeek) == "sk-second", "Другой ключ не тронут")
    }

    @Test("Две правки одного ключа без связи сходятся к правке с поздней меткой часов, на обоих Mac одинаково")
    func concurrentEditsConverge() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        a.connection.isOnline = false
        b.connection.isOnline = false
        // B правит раньше по времени, но его часы впереди: побеждает метка, а не порядок прихода.
        b.wall.set(90_000)
        try await b.saveServiceKey("sk-from-b", for: deepSeek)
        a.wall.set(60_000)
        try await a.saveServiceKey("sk-from-a", for: deepSeek)

        a.connection.isOnline = true
        b.connection.isOnline = true
        a.engine.syncNow()
        b.engine.syncNow()
        try await eventually("ключ сошёлся", within: .seconds(10)) {
            try a.serviceKeys?.value(for: deepSeek) == "sk-from-b" && b.serviceKeys?.value(for: deepSeek) == "sk-from-b"
        }
    }

    @Test("Новое устройство получает текущие ключи сразу — из журнала и после сжатия журнала из снимка")
    func newDeviceGetsCurrentKeys() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }
        try await a.saveServiceKey("sk-shared", for: deepSeek)
        try await eventually("ключ дошёл до B", within: .seconds(10)) { try b.serviceKeys?.value(for: deepSeek) == "sk-shared" }

        let c = try EngineTestMac(name: "iPhone", wallMillis: 30_000)
        c.serviceKeys = InMemoryServiceKeys()
        defer { c.stop() }
        try await c.join(server, code: a.makeJoinCode())
        c.start()
        try await eventually("C получил ключ из журнала", within: .seconds(10)) { try c.serviceKeys?.value(for: deepSeek) == "sk-shared" }

        try await b.saveServiceKey("ntn_later", for: notion)
        try await eventually("все готовы", within: .seconds(10)) {
            try a.serviceKeys?.value(for: notion) == "ntn_later" && c.serviceKeys?.value(for: notion) == "ntn_later"
                && a.engine.status == .ready && b.engine.status == .ready && c.engine.status == .ready
        }
        try await a.engine.uploadSnapshot()
        try await eventually("журнал сжат", within: .seconds(10)) { try await server.isCompacted() }

        let d = try EngineTestMac(name: "Mac D", wallMillis: 40_000)
        d.serviceKeys = InMemoryServiceKeys()
        defer { d.stop() }
        try await d.join(server, code: a.makeJoinCode())
        d.start()
        try await eventually("D получил ключи", within: .seconds(10)) {
            try d.serviceKeys?.value(for: deepSeek) == "sk-shared" && d.serviceKeys?.value(for: notion) == "ntn_later"
        }
    }

    @Test("Снимок несёт ключи с их метками; применённый снимок кладёт их в связку ключей и говорит, какие поменялись")
    func snapshotCarriesKeys() async throws {
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        a.serviceKeys = InMemoryServiceKeys()
        try await a.saveServiceKey("sk-snap", for: deepSeek)
        let keys = try #require(a.serviceKeys)
        let snapshot = try SyncSnapshot.make(seq: 7, from: a.store, serviceKeys: try ServiceKeys.current(keys: keys, in: a.store))
        let sent = try #require(snapshot.serviceKeys?.first)
        #expect(sent.name == deepSeek && sent.value == "sk-snap")

        let b = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
        let bKeys = InMemoryServiceKeys()
        let applier = RemoteChangeApplier(store: b.store, openDocuments: nil, localDeviceName: "Mac B",
                                          serviceKeys: ServiceKeySync(store: b.store, keys: bKeys))
        try b.store.write { tx in
            try SyncAccountStore.save(SyncAccount(serverURL: URL(string: "https://fake.sync.test")!, deviceId: "b", deviceName: "Mac B"),
                                      in: tx.database)
        }
        var changed: Set<String> = []
        applier.onApplied = { changed = $0.changedServiceKeys }
        let report = try applier.apply(snapshot)
        #expect(report.changedServiceKeys == [deepSeek] && changed == [deepSeek])
        try await eventually("ключ из снимка в связке ключей", within: .seconds(5)) {
            try bKeys.value(for: deepSeek) == "sk-snap" && !ServiceKeys.hasWaiting(in: b.store)
        }

        let again = try applier.apply(snapshot)
        #expect(again.changedServiceKeys.isEmpty, "Тот же снимок второй раз ничего не меняет")
    }

    @Test("Ключ на Mac, где синхронизация уже была включена до обновления MyNotion, после обновления уходит на другие")
    func existingKeyIsSentAfterUpdate() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server, aKeys: nil)
        defer { a.stop(); b.stop() }

        // На A ключ лежал в связке ключей ещё до синхронизации ключей.
        try a.updateToServiceKeys(InMemoryServiceKeys([deepSeek: "sk-typed-before-update"]))
        try await eventually("ключ A дошёл до B", within: .seconds(10)) {
            try b.serviceKeys?.value(for: deepSeek) == "sk-typed-before-update"
        }
    }

    @Test("MyNotion без синхронизации ключей принимает остальные правки; после обновления сам получает ключи, без лишних пачек")
    func olderVersionKeepsSyncingAndCatchesUpAfterUpdate() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server, bKeys: nil)
        defer { a.stop(); b.stop() }

        try await a.saveServiceKey("sk-only-on-a", for: deepSeek)
        let page = try a.store.write { try $0.createPage(title: "После ключа") }
        try await eventually("страница дошла до старого B", within: .seconds(10)) {
            try b.store.pageOutline().contains { $0.id == page.id }
        }
        try await eventually("B без ошибок", within: .seconds(10)) { b.engine.status == .ready }

        let updated = InMemoryServiceKeys()
        try b.updateToServiceKeys(updated)
        try await eventually("обновлённый B получил ключ", within: .seconds(10)) { try updated.value(for: deepSeek) == "sk-only-on-a" }
        try await eventually("все отправили всё", within: .seconds(10)) { a.engine.status == .ready && b.engine.status == .ready }

        let fake = try #require(server as? FakeTestServer).fake
        let settled = await fake.lastSeq
        try await Task.sleep(for: .milliseconds(400))
        #expect(await fake.lastSeq == settled, "Ответ на просьбу о ключах не вызывает новых просьб")
    }

    @Test("Пачка с ключами — прежний формат 4: MyNotion без синхронизации ключей читает её и пропускает ключи")
    func batchStaysReadableForOlderVersion() throws {
        let hlc = HybridTimestamp(wallMillis: 1_760_000_000_000, counter: 0, deviceId: UUID())
        let pageId = UUID()
        let batch = SyncBatch(deviceId: "d", deviceName: "Mac", changes: [SyncChange(entity: .page, id: pageId, value: .title("Т"), hlc: hlc)],
                              serviceKeys: [ServiceKeyChange(name: deepSeek, value: "sk-x", hlc: hlc)], requestsServiceKeys: true)
        #expect(batch.formatVersion == 4)
        let data = try SyncJSON.encoder().encode(batch)
        let older = try SyncJSON.decoder().decode(BatchBeforeServiceKeys.self, from: data)
        #expect(older.changes.map(\.id) == [pageId])
        #expect(try SyncJSON.decoder().decode(SyncBatch.self, from: data) == batch)

        let plain = SyncBatch(deviceId: "d", deviceName: "Mac", changes: [])
        let text = String(decoding: try SyncJSON.encoder().encode(plain), as: UTF8.self)
        #expect(!text.contains("serviceKeys") && !text.contains("requestsServiceKeys"), "Без ключей пачка та же, что раньше")

        let snapshot = SyncSnapshot(seq: 3, changes: [], knowledge: ClockKnowledge(), serviceKeys: batch.serviceKeys)
        _ = try SyncJSON.decoder().decode(SnapshotBeforeServiceKeys.self, from: try SyncJSON.encoder().encode(snapshot))
    }

    @Test("Ключ с незнакомым именем (из будущей версии) пропускается, остальное из пачки применяется")
    func unknownKeyNameIsSkipped() async throws {
        let mac = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
        let keys = InMemoryServiceKeys()
        let applier = RemoteChangeApplier(store: mac.store, openDocuments: nil, localDeviceName: "Mac B",
                                          serviceKeys: ServiceKeySync(store: mac.store, keys: keys))
        let hlc = HybridTimestamp(wallMillis: 30_000, counter: 0, deviceId: UUID())
        let page = UUID()
        let changes = ChangeEncoding.fullPage(Page(id: page, title: "Из пачки", sortKey: .between(nil, nil),
                                                                createdAt: Date(), updatedAt: Date()))
            .map { change in var change = change; change.hlc = hlc; return change }
        let batch = SyncBatch(deviceId: "a", deviceName: "Mac A", changes: changes,
                              serviceKeys: [ServiceKeyChange(name: "someFutureService", value: "secret", hlc: hlc),
                                            ServiceKeyChange(name: deepSeek, value: "sk-known", hlc: hlc)])
        try applier.apply([ReceivedBatch(seq: 1, batchId: "x", batch: batch)])
        #expect(try mac.store.page(page)?.title == "Из пачки")
        try await eventually("известный ключ в связке ключей", within: .seconds(5)) { try keys.value(for: deepSeek) == "sk-known" }
        #expect(try keys.value(for: "someFutureService") == nil)
    }

    @Test("Ключ не лежит открытым текстом ни в базе, ни в очереди, ни в пачках на сервере, ни в описании изменения")
    func keyNeverInPlaintext() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }
        let secret = "sk-very-secret-4f1c9e"

        a.connection.isOnline = false
        try await a.saveServiceKey(secret, for: deepSeek)
        #expect(try !databaseFiles(of: a).contains(Data(secret.utf8)), "В очереди A ключа нет — только отметка «отправить»")
        a.connection.isOnline = true
        a.engine.syncNow()
        try await eventually("ключ дошёл до B", within: .seconds(10)) { try b.serviceKeys?.value(for: deepSeek) == secret }
        try await eventually("всё отправлено", within: .seconds(10)) { a.engine.status == .ready && b.engine.status == .ready }

        for mac in [a, b] {
            #expect(try !databaseFiles(of: mac).contains(Data(secret.utf8)), "\(mac.name): в файлах базы ключа нет")
        }
        let journal = try await b.connection.changes(after: 0, wait: 0).items
        #expect(!journal.isEmpty && journal.allSatisfy { !$0.ciphertext.contains(secret) && !Data(base64Encoded: $0.ciphertext)!.contains(Data(secret.utf8)) })
        let change = ServiceKeyChange(name: deepSeek, value: secret, hlc: HybridTimestamp(wallMillis: 1, counter: 0, deviceId: UUID()))
        #expect(!String(describing: change).contains(secret) && !String(reflecting: change).contains(secret))
        #expect(!String(describing: SyncBatch(deviceId: "d", deviceName: "M", changes: [], serviceKeys: [change])).contains(secret))
    }

    @Test("Выключенная синхронизация: ключ сохраняется только на этом Mac; при включении уходит на другие")
    func keySavedWhileDisabledIsSentOnEnable() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        a.serviceKeys = InMemoryServiceKeys()
        try await a.saveServiceKey("sk-before-sync", for: deepSeek)
        try await a.connectFirst(server)
        let b = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
        b.serviceKeys = InMemoryServiceKeys()
        try await b.join(server, code: a.makeJoinCode())
        a.start()
        b.start()
        defer { a.stop(); b.stop() }
        try await eventually("ключ дошёл до B", within: .seconds(10)) { try b.serviceKeys?.value(for: deepSeek) == "sk-before-sync" }
    }

    @Test("Связка ключей отказывает в записи — страницы из той же пачки всё равно приходят; ключ ложится, когда связка оживёт")
    func refusingKeychainDoesNotStopPages() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }
        let bKeys = try #require(b.serviceKeys)
        bKeys.refusesWrites = true

        try await a.saveServiceKey("sk-while-locked", for: deepSeek)
        let page = try a.store.write { try $0.createPage(title: "Рядом с ключом") }
        try await eventually("страница дошла до B", within: .seconds(10)) {
            try b.store.pageOutline().contains { $0.id == page.id } && b.engine.status == .ready
        }
        #expect(try bKeys.value(for: deepSeek) == nil)

        bKeys.refusesWrites = false
        try await eventually("ключ лёг в связку ключей B после повтора", within: .seconds(10)) {
            try bKeys.value(for: deepSeek) == "sk-while-locked"
        }
    }

    @Test("Ключ не успел лечь в связку ключей до перезапуска — после перезапуска устройство получает его снова")
    func keyNotWrittenBeforeRestartArrivesAfterRestart() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        // Повтор в этом запуске не успеет: ключ приходит только после перезапуска.
        let (a, b) = try await connectedPair(server, keyRetryDelay: .seconds(600))
        defer { a.stop(); b.stop() }
        let bKeys = try #require(b.serviceKeys)
        bKeys.refusesWrites = true

        try await a.saveServiceKey("sk-before-restart", for: deepSeek)
        let page = try a.store.write { try $0.createPage(title: "До перезапуска") }
        try await eventually("пачка применена на B", within: .seconds(10)) {
            try b.store.pageOutline().contains { $0.id == page.id } && b.engine.status == .ready
        }
        b.stop()
        bKeys.refusesWrites = false
        try b.restart()
        try await eventually("ключ на B после перезапуска", within: .seconds(10)) {
            try bKeys.value(for: deepSeek) == "sk-before-restart"
        }
    }

    @Test("Ключ, введённый до обновления MyNotion, уступает правке после обновления, даже если его устройство обновилось позже")
    func keyFromBeforeUpdateLosesToEditAfterUpdate() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server, aKeys: nil)
        defer { a.stop(); b.stop() }

        try await b.saveServiceKey("sk-edited-on-b", for: deepSeek)
        try await eventually("B отправил ключ", within: .seconds(10)) { b.engine.status == .ready }
        a.wall.set(90_000)
        let aKeys = InMemoryServiceKeys([deepSeek: "sk-typed-before-update"])
        try a.updateToServiceKeys(aKeys)
        try await eventually("ключ сошёлся к правке B", within: .seconds(10)) {
            try aKeys.value(for: deepSeek) == "sk-edited-on-b" && b.serviceKeys?.value(for: deepSeek) == "sk-edited-on-b"
                && a.engine.status == .ready && b.engine.status == .ready
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try aKeys.value(for: deepSeek) == "sk-edited-on-b" && b.serviceKeys?.value(for: deepSeek) == "sk-edited-on-b")
    }

    @Test("Ключ, удалённый после обновления, не воскресает от устройства, где он лежал с давних пор")
    func removedKeyDoesNotComeBackFromOldDevice() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server, aKeys: nil, bKeys: InMemoryServiceKeys([deepSeek: "sk-shared"]))
        defer { a.stop(); b.stop() }

        try await b.saveServiceKey("", for: deepSeek)
        try await eventually("B отправил удаление", within: .seconds(10)) { b.engine.status == .ready }
        a.wall.set(90_000)
        let aKeys = InMemoryServiceKeys([deepSeek: "sk-shared"])
        try a.updateToServiceKeys(aKeys)
        try await eventually("ключ удалён на обоих", within: .seconds(10)) {
            try aKeys.value(for: deepSeek) == nil && b.serviceKeys?.value(for: deepSeek) == nil
                && a.engine.status == .ready && b.engine.status == .ready
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try aKeys.value(for: deepSeek) == nil && b.serviceKeys?.value(for: deepSeek) == nil)
    }

    @Test("База не записала метку — ключ в связке ключей прежний: локально новый ключ без метки не остаётся")
    func failedDatabaseWriteKeepsOldKey() async throws {
        let mac = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        mac.serviceKeys = InMemoryServiceKeys()
        try await mac.saveServiceKey("sk-first", for: deepSeek)
        try mac.store.write { transaction in
            for event in ["INSERT", "UPDATE"] {
                try transaction.database.execute(sql: """
                    CREATE TEMP TRIGGER refuse_service_key_\(event) BEFORE \(event) ON app_meta
                    WHEN NEW.key LIKE 'sync.serviceKey%' BEGIN SELECT RAISE(ABORT, 'база не пишет'); END
                    """)
            }
        }
        do {
            try await mac.saveServiceKey("sk-second", for: deepSeek)
            Issue.record("Сохранение должно было сообщить об ошибке базы")
        } catch {}
        #expect(try mac.serviceKeys?.value(for: deepSeek) == "sk-first")
    }

    // MARK: Помощники

    private func connectedPair(_ server: any SyncTestServer, aKeys: InMemoryServiceKeys? = InMemoryServiceKeys(),
                               bKeys: InMemoryServiceKeys? = InMemoryServiceKeys(),
                               keyRetryDelay: Duration = .milliseconds(50)) async throws -> (EngineTestMac, EngineTestMac) {
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        a.serviceKeys = aKeys
        a.keyRetryDelay = keyRetryDelay
        try await a.connectFirst(server)
        let b = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
        b.serviceKeys = bKeys
        b.keyRetryDelay = keyRetryDelay
        try await b.join(server, code: a.makeJoinCode())
        a.start()
        b.start()
        return (a, b)
    }

    /// Все файлы базы Mac (сама база, журнал WAL и прочее) одной последовательностью байтов.
    private func databaseFiles(of mac: EngineTestMac) throws -> Data {
        try mac.store.database.dbWriter.writeWithoutTransaction { db in _ = try? db.checkpoint(.passive) }
        let files = try FileManager.default.contentsOfDirectory(at: mac.folder.url, includingPropertiesForKeys: nil)
        return try files.reduce(into: Data()) { $0 += try Data(contentsOf: $1) }
    }
}

/// Пачка так, как её читает MyNotion без синхронизации ключей.
private struct BatchBeforeServiceKeys: Decodable {
    let formatVersion: Int
    let deviceId: String
    let deviceName: String
    let changes: [SyncChange]
}

private struct SnapshotBeforeServiceKeys: Decodable {
    let formatVersion: Int
    let seq: Int
    let changes: [SyncChange]
    let knowledge: ClockKnowledge
}
