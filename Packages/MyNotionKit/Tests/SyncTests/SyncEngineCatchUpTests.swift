import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Один круг без долгого ожидания (`SyncEngine.catchUp()`): iPhone разбудил тихий пуш, цикл остановлен,
/// на всё — секунды, которые дала система. Отправить своё, забрать и применить новое, подтвердить.
@MainActor
@Suite("Синхронизация одним кругом по пушу")
struct SyncEngineCatchUpTests {
    @Test("Остановленный iPhone одним кругом забирает правки Mac, отправляет свои и подтверждает — без долгого ожидания")
    func catchUpPullsSendsAndAcknowledges() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let mac = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        try await mac.connectFirst(server)
        mac.start()
        defer { mac.stop() }
        let phone = try EngineTestMac(name: "iPhone", wallMillis: 20_000)
        try await phone.join(server, code: mac.makeJoinCode())

        // iPhone в фоне: цикл не идёт. На Mac — новая страница, на iPhone — своя, ещё не отправленная.
        let macPage = try mac.store.write { try $0.createPage(title: "С Mac, пока iPhone спал") }
        try await eventually("Mac отправил страницу", within: .seconds(10)) { try Outbox(store: mac.store).isEmpty() }
        let phonePage = try phone.store.write { try $0.createPage(title: "С iPhone до сна") }

        let started = ContinuousClock.now
        try await phone.engine.catchUp()
        #expect(ContinuousClock.now - started < .seconds(5), "Круг не ждёт новых пачек")

        #expect(try phone.store.page(macPage.id)?.title == "С Mac, пока iPhone спал")
        #expect(try Outbox(store: phone.store).isEmpty())
        #expect(phone.engine.status == .ready)
        try await eventually("страница iPhone дошла до Mac", within: .seconds(10)) { try mac.store.page(phonePage.id) != nil }
        let account = try #require(try SyncAccountStore(store: phone.store).account())
        let me = try await phone.connection.devices().first { $0.deviceId == account.deviceId }
        #expect(me?.lastAckSeq == account.lastPulledSeq, "Сервер знает, что iPhone всё забрал: будить его снова незачем")
    }

    @Test("Пустой пуш безвреден: круг ничего не меняет и сразу кончается; повтор — тоже")
    func emptyCatchUpIsHarmless() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let mac = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        try await mac.connectFirst(server)
        let phone = try EngineTestMac(name: "iPhone", wallMillis: 20_000)
        try await phone.join(server, code: mac.makeJoinCode())
        let before = try contentDump(phone.store)

        let started = ContinuousClock.now
        try await phone.engine.catchUp()
        try await phone.engine.catchUp()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(try contentDump(phone.store) == before)
        #expect(phone.engine.status == .ready)
    }

    @Test("Без связи круг бросает ошибку и оставляет правки в очереди; после него цикл запускается как обычно")
    func offlineCatchUpFailsAndLoopStartsAfter() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let mac = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        try await mac.connectFirst(server)
        mac.start()
        defer { mac.stop() }
        let phone = try EngineTestMac(name: "iPhone", wallMillis: 20_000)
        try await phone.join(server, code: mac.makeJoinCode())
        defer { phone.stop() }
        let page = try phone.store.write { try $0.createPage(title: "Ждёт связи") }

        phone.connection.isOnline = false
        await #expect(throws: (any Error).self) { try await phone.engine.catchUp() }
        #expect(phone.engine.status.isError)
        #expect(try !Outbox(store: phone.store).isEmpty())

        phone.connection.isOnline = true
        phone.start()
        try await eventually("правка ушла после возвращения", within: .seconds(10)) { try mac.store.page(page.id) != nil }
    }

    @Test("Пока цикл идёт, круг его только будит и сам ничего не делает")
    func catchUpWhileLoopRunsOnlyWakes() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let mac = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        try await mac.connectFirst(server)
        let phone = try EngineTestMac(name: "iPhone", wallMillis: 20_000)
        try await phone.join(server, code: mac.makeJoinCode())
        phone.start()
        defer { phone.stop() }
        try await eventually("цикл iPhone ждёт пачки", within: .seconds(10)) { phone.engine.status == .ready }

        let started = ContinuousClock.now
        try await phone.engine.catchUp()
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
