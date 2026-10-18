import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Два и три Mac с настоящим циклом синхронизации (`SyncEngine`) через сервер: правка доходит быстро (SC-007),
/// правки без связи не теряются (SC-008), после сжатия журнала новый Mac догоняет со снимка.
@MainActor
@Suite("Сходимость через сервер", .serialized)
struct SyncConvergenceTests {
    @Test("Правка на одном Mac появляется на другом не позже чем через 10 секунд", arguments: SyncTestServerKind.available)
    func editArrivesWithinTenSeconds(_ kind: SyncTestServerKind) async throws {
        let server = try await kind.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        let started = ContinuousClock.now
        let page = try a.store.write { try $0.createPage(title: "Пишу на A") }
        try await eventually("страница дошла до B", within: .seconds(10)) {
            try b.store.pageOutline().contains { $0.id == page.id && $0.title == "Пишу на A" }
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(10), "Дошла за \(elapsed)")
        try await eventually("оба Mac отправили всё", within: .seconds(10)) { a.engine.status == .ready && b.engine.status == .ready }
    }

    @Test("Оба Mac правят без связи, связь возвращается — потеряно 0 правок", arguments: SyncTestServerKind.available)
    func offlineEditsAreNotLost(_ kind: SyncTestServerKind) async throws {
        let server = try await kind.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        let shared = try a.store.write { tx in
            let page = try tx.createPage(title: "Общая")
            var key: FractionalSortKey?
            var ids: [UUID] = []
            for text in ["один", "два", "три"] {
                key = .between(key, nil)
                ids.append(try tx.insertBlock(Block(pageId: page.id, text: InlineText(text), sortKey: key!)).id)
            }
            return (page: page.id, blocks: ids)
        }
        try await eventually("страница дошла до B", within: .seconds(10)) {
            try b.store.pageContent(shared.page)?.blocks.count == 4
        }

        a.connection.isOnline = false
        b.connection.isOnline = false
        try await eventually("оба видят, что связи нет", within: .seconds(10)) {
            a.engine.status.isError && b.engine.status.isError
        }

        try a.setText("один — правка A", ofBlock: shared.blocks[0])
        try a.setText("три — правка A", ofBlock: shared.blocks[2])
        let newOnA = try a.store.write { try $0.createPage(title: "Новая на A без связи") }
        try b.setText("два — правка B", ofBlock: shared.blocks[1])
        try b.setText("три — правка B", ofBlock: shared.blocks[2])
        let newOnB = try b.store.write { try $0.createPage(title: "Новая на B без связи") }

        a.connection.isOnline = true
        b.connection.isOnline = true
        a.engine.syncNow()
        b.engine.syncNow()

        let edits = ["один — правка A", "два — правка B", "три — правка A", "три — правка B"]
        try await eventually("правки сошлись", within: .seconds(20)) {
            try [a, b].allSatisfy { mac in
                let seen = try mac.allTextVersions(of: shared.page)
                let pageIds = try mac.store.pageOutline().map(\.id)
                return edits.allSatisfy(seen.contains) && pageIds.contains(newOnA.id) && pageIds.contains(newOnB.id)
            }
        }
        for mac in [a, b] {
            let blocks = try #require(try mac.store.pageContent(shared.page)).blocks.map(\.text.string)
            #expect(blocks.contains("один — правка A") && blocks.contains("два — правка B"), "\(mac.name): разные блоки слились")
            let conflicts = try mac.store.unresolvedConflicts(ofPage: shared.page)
            #expect(conflicts.count == 1, "\(mac.name): один блок с двух сторон — «Две версии»")
        }
    }

    @Test("Журнал сжимается после снимка, третий Mac подключается и догоняет со снимка", arguments: SyncTestServerKind.available)
    func thirdMacJoinsFromSnapshot(_ kind: SyncTestServerKind) async throws {
        let server = try await kind.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        for index in 1...5 {
            try a.store.write { tx in _ = try tx.createPage(title: "Страница \(index)") }
        }
        let fromB = try b.store.write { try $0.createPage(title: "С Mac B") }
        try await eventually("A и B сошлись", within: .seconds(10)) {
            try a.titles() == b.titles() && a.titles().count == 6
                && a.engine.status == .ready && b.engine.status == .ready
        }

        try await a.engine.uploadSnapshot()
        try await eventually("журнал сжат", within: .seconds(10)) { try await server.isCompacted() }

        let c = try EngineTestMac(name: "Mac C", wallMillis: 50_000)
        defer { c.stop() }
        try await c.join(server, code: a.makeJoinCode())
        c.start()
        try await eventually("C догнал со снимка", within: .seconds(10)) {
            try c.titles() == a.titles()
        }
        #expect(try c.store.pageOutline().contains { $0.id == fromB.id })

        let fromC = try c.store.write { try $0.createPage(title: "С Mac C") }
        try await eventually("правка C дошла до A и B", within: .seconds(10)) {
            try a.store.pageOutline().contains { $0.id == fromC.id } && b.store.pageOutline().contains { $0.id == fromC.id }
        }
    }

    @Test("Пачка более нового формата ждёт: она не применяется, Юрий видит «обновите MyNotion на этом Mac»")
    func newerFormatBatchWaits() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }
        try await eventually("оба на связи", within: .seconds(10)) { a.engine.status == .ready && b.engine.status == .ready }

        a.engine.formatVersionForTests = SyncBatch.currentFormatVersion + 1
        let page = try a.store.write { try $0.createPage(title: "Из будущего") }
        try await eventually("B сообщил об обновлении", within: .seconds(10)) {
            if case .error(let message) = b.engine.status { message.localizedCaseInsensitiveContains("обновите MyNotion") } else { false }
        }
        #expect(try !b.store.pageOutline().contains { $0.id == page.id })
        let pulledBefore = try #require(try SyncAccountStore(store: b.store).account()).lastPulledSeq
        try await Task.sleep(for: .milliseconds(300))
        #expect(try SyncAccountStore(store: b.store).account()?.lastPulledSeq == pulledBefore, "Пачка ждёт: номер не сдвинут")
    }

    @Test("Первый Mac находит себя по токену (/devices/me), даже когда на сервере уже несколько Mac; отключённый токен не принят",
          arguments: SyncTestServerKind.available)
    func firstMacIdentifiesItselfByToken(_ kind: SyncTestServerKind) async throws {
        let server = try await kind.start()
        defer { server.stop() }
        let token = try await server.bootstrapToken(name: "Mac A")
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        try await a.connectFirst(server, token: token)
        let b = try EngineTestMac(name: "Mac B", wallMillis: 10_000)
        try await b.join(server, code: a.makeJoinCode())

        // Синхронизацию на A выключили и включили снова тем же токеном: на сервере уже два устройства.
        let again = try EngineTestMac(name: "Mac A", wallMillis: 20_000)
        try await again.connectFirst(server, token: token)
        #expect(again.account.deviceId == a.account.deviceId, "Mac взял свой id, а не чужой")
        #expect(try await b.connection.devices().count == 2)

        try await b.connection.deleteDevice(a.account.deviceId)
        await #expect(throws: SyncServerError.unauthorized) { try await again.connection.currentDevice() }
    }

    // MARK: Помощники

    private func connectedPair(_ server: any SyncTestServer) async throws -> (EngineTestMac, EngineTestMac) {
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        try await a.connectFirst(server)
        let b = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
        try await b.join(server, code: a.makeJoinCode())
        a.start()
        b.start()
        return (a, b)
    }
}

/// Ждать условия, проверяя его часто; без жёстких пауз.
@MainActor
func eventually(_ what: String, within limit: Duration, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    if try await condition() { return }
    Issue.record("Не дождались: \(what) за \(limit)")
    throw EventuallyTimeout()
}

struct EventuallyTimeout: Error {}
