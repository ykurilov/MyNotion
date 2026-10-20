import Foundation
import Testing
@testable import NotesCore
@testable import PageVersions
@testable import Sync

/// Когда пишутся версии (contracts/page-operations.md, «История версий»; research R11): отметка от своей правки и от пачки
/// с другого Mac, не чаще раза в минуту, после 5 с тишины; избранное и открытие не отмечают; первое открытие без версий —
/// снимок «как было»; закрытие окна — снимки всех отмеченных; до готовности редактора — ни одного снимка.
@MainActor
@Suite("Версии: когда пишутся")
struct PageVersionRecorderTests {
    let mac: VersionsTestMac

    init() throws {
        mac = try VersionsTestMac(name: "Mac A")
    }

    @Test("Своя правка отмечает страницу; через 5 с тишины — версия с именем этого Mac")
    func ownEditGivesVersion() throws {
        mac.recorder.start()
        let page = try mac.page("Своя", texts: ["было"])
        #expect(try mac.dueCount() == 1)
        mac.clock.advance(by: 4.9)
        #expect(try mac.versionList(page.id).isEmpty, "Версия раньше 5 с тишины")
        mac.clock.advance(by: 0.2)
        let versions = try mac.versionList(page.id)
        #expect(versions.count == 1)
        #expect(versions.first?.deviceName == "Mac A")
        #expect(try mac.dueCount() == 0, "Отметка не снята после снимка")
        let snapshot = try #require(try mac.versions.snapshot(versions[0].id))
        #expect(snapshot.blocks.map(\.text.string) == ["было"])
    }

    @Test("Пачка с другого Mac отмечает страницу; автор версии — тот Mac")
    func remoteBatchGivesVersionByThatMac() throws {
        let other = try VersionsTestMac(name: "Mac B", syncs: true)
        let here = try VersionsTestMac(name: "Mac A", clock: mac.clock, syncs: true)
        here.recorder.start()
        let page = try other.page("С другого Mac", texts: ["оттуда"])
        try here.receive(other.takeOutgoing())
        #expect(try here.dueCount() == 1)
        here.clock.advance(by: 6)
        let versions = try here.versionList(page.id)
        #expect(versions.count == 1)
        #expect(versions.first?.deviceName == "Mac B")
        #expect(try here.versions.snapshot(versions[0].id)?.blocks.map(\.text.string) == ["оттуда"])
    }

    @Test("Не чаще раза в минуту на страницу")
    func atMostOncePerMinute() throws {
        mac.recorder.start()
        let page = try mac.page("Минута", texts: ["1"])
        mac.clock.advance(by: 5)
        #expect(try mac.versionList(page.id).count == 1)
        let block = try #require(try mac.blocks(page.id).first)
        mac.clock.advance(by: 10)
        try mac.setText("2", ofBlock: block.id)
        mac.clock.advance(by: 30)
        #expect(try mac.versionList(page.id).count == 1, "Вторая версия раньше минуты после первой")
        mac.clock.advance(by: 20)
        let versions = try mac.versionList(page.id)
        #expect(versions.count == 2)
        #expect(try mac.versions.snapshot(versions[0].id)?.blocks.first?.text.string == "2", "Новая версия — первой в списке")
        #expect(versions[0].createdAt.timeIntervalSince(versions[1].createdAt) >= 60)
    }

    @Test("Пока правят, версия ждёт 5 с тишины")
    func waitsForQuiet() throws {
        mac.recorder.start()
        let page = try mac.page("Тишина", texts: ["0"])
        let block = try #require(try mac.blocks(page.id).first)
        for step in 1...30 {
            mac.clock.advance(by: 3)
            try mac.setText("\(step)", ofBlock: block.id)
        }
        #expect(try mac.versionList(page.id).isEmpty, "Версия посреди набора")
        mac.clock.advance(by: 5)
        let versions = try mac.versionList(page.id)
        #expect(versions.count == 1)
        #expect(try mac.versions.snapshot(versions[0].id)?.blocks.first?.text.string == "30")
    }

    @Test("Избранное и открытие страницы версий не порождают")
    func favoriteAndVisitDoNotMark() throws {
        mac.recorder.start()
        let page = try mac.page("Избранная", texts: ["а"])
        mac.clock.advance(by: 6)
        #expect(try mac.versionList(page.id).count == 1)
        try mac.tree.addToFavorites(page.id)
        try mac.updatePage(page.id) { $0.visitedAt = Date() }
        #expect(try mac.dueCount() == 0)
        mac.clock.advance(by: 120)
        #expect(try mac.versionList(page.id).count == 1)
    }

    @Test("Вид страницы, обложка, иконка и название отмечают страницу")
    func appearanceMarks() throws {
        mac.recorder.start()
        let page = try mac.page("Вид", texts: ["а"])
        mac.clock.advance(by: 6)
        for change in [{ (page: inout Page) in page.isFullWidth = true }, { $0.isSmallText = true }, { $0.icon = "🌿" },
                       { $0.title = "Новое" }, { $0.cover = PageCover(source: .gallery("solid_red")) }] {
            try mac.updatePage(page.id, change)
            #expect(try mac.dueCount() == 1)
            mac.clock.advance(by: 61)
            #expect(try mac.dueCount() == 0)
        }
        #expect(try mac.versionList(page.id).count == 6)
    }

    @Test("Первое открытие страницы без версий — снимок «как было»; повторное — ничего")
    func firstOpenSnapshot() throws {
        let page = try mac.page("Старая", texts: ["до первой правки"])
        try mac.versions.clearDue(pageId: page.id, upTo: mac.clock.now)
        mac.recorder.start()
        mac.recorder.pageOpened(page.id)
        mac.clock.runDue()
        let versions = try mac.versionList(page.id)
        #expect(versions.count == 1)
        #expect(try mac.versions.snapshot(versions[0].id)?.blocks.map(\.text.string) == ["до первой правки"])
        mac.recorder.pageOpened(page.id)
        mac.clock.advance(by: 120)
        #expect(try mac.versionList(page.id).count == 1)
    }

    @Test("Закрытие окна: снимки всех отмеченных сразу, без ожидания")
    func closingRecordsAllDue() async throws {
        mac.recorder.start()
        let first = try mac.page("Первая", texts: ["1"])
        let second = try mac.page("Вторая", texts: ["2"])
        mac.clock.advance(by: 1)
        await mac.recorder.recordAllDue()
        #expect(try mac.versionList(first.id).count == 1)
        #expect(try mac.versionList(second.id).count == 1)
        #expect(try mac.dueCount() == 0)
    }

    @Test("До готовности редактора — ни одного снимка; после — отмеченное и первое открытие")
    func nothingBeforeEditorReady() async throws {
        let edited = try mac.page("Правка до готовности", texts: ["правка"])
        let opened = try mac.page("Открыта до готовности", texts: ["как было"])
        try mac.versions.clearDue(pageId: opened.id, upTo: mac.clock.now)
        mac.recorder.pageOpened(opened.id)
        mac.clock.advance(by: 120)
        await mac.recorder.recordAllDue()
        mac.recorder.recordAllDueBeforeQuit()
        #expect(try mac.versionList(edited.id).isEmpty)
        #expect(try mac.versionList(opened.id).isEmpty)
        mac.recorder.start()
        mac.clock.runDue()
        #expect(try mac.versionList(edited.id).count == 1)
        #expect(try mac.versionList(opened.id).count == 1)
    }

    @Test("Сводка версии — разница с прошлой")
    func summaryAgainstPrevious() throws {
        mac.recorder.start()
        let page = try mac.page("Сводка", texts: ["а", "б"])
        mac.clock.advance(by: 6)
        let block = try #require(try mac.blocks(page.id).first)
        try mac.setText("а2", ofBlock: block.id)
        try mac.updatePage(page.id) { $0.title = "Сводка 2" }
        mac.clock.advance(by: 61)
        let versions = try mac.versionList(page.id)
        #expect(versions.count == 2)
        #expect(versions[1].summary.isFirst)
        #expect(versions[0].summary == VersionSummary(titleChanged: true, blocksChanged: 1))
    }

    @Test("Снимок по запросу (история, восстановление) — только если есть неснятые правки")
    func recordPendingNow() async throws {
        mac.recorder.start()
        let page = try mac.page("Сейчас", texts: ["а"])
        #expect(try await mac.recorder.recordPending(page.id) != nil, "Правка без версии — снимок сразу")
        #expect(try mac.versionList(page.id).count == 1)
        #expect(try await mac.recorder.recordPending(page.id) == nil, "Без новых правок второй снимок не нужен")
        #expect(try mac.versionList(page.id).count == 1)
    }

    @Test("Снимок по запросу и при закрытии окна — на очереди записывателя, а не на главном потоке; выход ждёт снимков")
    func onDemandRecordsOffMainThread() async throws {
        let threads = ThreadLog()
        mac.recorder.onRecorded = { _ in threads.record(Thread.isMainThread) }
        mac.recorder.start()
        let page = try mac.page("По запросу", texts: ["а"])
        #expect(try await mac.recorder.recordPending(page.id) != nil)
        try mac.setText("б", ofBlock: try #require(try mac.blocks(page.id).first).id)
        await mac.recorder.recordAllDue()
        try mac.setText("в", ofBlock: try #require(try mac.blocks(page.id).first).id)
        mac.recorder.recordAllDueBeforeQuit()
        #expect(try mac.versionList(page.id).count == 3)
        let onMain = threads.values
        #expect(onMain.prefix(2) == [false, false], "Снимок по запросу или при закрытии окна — на главном потоке: \(onMain)")
    }

    @Test("Запись версии по таймеру — не на главном потоке")
    func recordsOffMainThread() async throws {
        let store = mac.store
        let versions = PageVersionStore(store: store)
        let recorder = PageVersionRecorder(store: store, versions: versions, timing: .init(minimumInterval: 0.05, quietPeriod: 0.05))
        recorder.installDueMarker(localDeviceName: "Mac A")
        let threads = ThreadLog()
        recorder.onRecorded = { _ in threads.record(Thread.isMainThread) }
        recorder.start()
        let page = try mac.page("Поток", texts: ["а"])
        for _ in 0..<100 where try versions.versions(ofPage: page.id).isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try versions.versions(ofPage: page.id).count == 1)
        #expect(threads.values == [false])
    }
}

final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Bool] = []
    func record(_ value: Bool) { lock.withLock { log.append(value) } }
    var values: [Bool] { lock.withLock { log } }
}
