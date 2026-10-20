import Foundation
import GRDB
import Testing
@testable import NotesCore
@testable import PageVersions

/// Прореживание (spec, Clarifications; contracts/page-operations.md): младше суток — все; от суток до 30 дней — последняя
/// в каждом часе; старше — последняя в каждом дне; последняя версия страницы остаётся всегда. Удаление страницы навсегда
/// стирает её версии и отметки.
@MainActor
@Suite("Версии: прореживание")
struct VersionPruningTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Makassar")!
        return calendar
    }

    /// Полдень 21.10.2026 по местному времени.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))! }

    private func at(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func kept(_ dates: [Date]) -> [Date] {
        let versions = dates.map { VersionStamp(id: UUID(), createdAt: $0) }
        let removed = VersionPruning.versionsToRemove(versions, now: now, calendar: calendar)
        return versions.filter { !removed.contains($0.id) }.map(\.createdAt).sorted()
    }

    @Test("Младше суток — все версии остаются, даже каждую минуту")
    func lastDayKeepsAll() {
        let dates = (0..<200).map { now.addingTimeInterval(-Double($0) * 60) }
        #expect(kept(dates).count == 200)
    }

    @Test("От суток до 30 дней — последняя в каждом часе")
    func hourlyUpToThirtyDays() {
        // 19 октября: 10:05, 10:40, 10:59 — один час; 11:01 — следующий.
        let dates = [at(day: 19, hour: 10, minute: 5), at(day: 19, hour: 10, minute: 40), at(day: 19, hour: 10, minute: 59),
                     at(day: 19, hour: 11, minute: 1), now]
        #expect(kept(dates) == [at(day: 19, hour: 10, minute: 59), at(day: 19, hour: 11, minute: 1), now])
    }

    @Test("Старше 30 дней — последняя в каждом дне")
    func dailyAfterThirtyDays() {
        let old = calendar.date(byAdding: .day, value: -40, to: now)!
        let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: old)!
        let evening = calendar.date(bySettingHour: 20, minute: 30, second: 0, of: old)!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: morning)!
        #expect(kept([morning, evening, nextDay, now]) == [evening, nextDay, now])
    }

    @Test("Ровно сутки и ровно 30 дней — граница правила")
    func boundaries() {
        let justUnderDay = now.addingTimeInterval(-86_399)
        let justUnderDayTwin = now.addingTimeInterval(-86_390)
        #expect(kept([justUnderDay, justUnderDayTwin, now]).count == 3, "Младше суток — все")
        let dayOld = now.addingTimeInterval(-86_400 - 60)
        let dayOldTwin = now.addingTimeInterval(-86_400 - 120)
        #expect(kept([dayOld, dayOldTwin, now]).count == 2, "Старше суток — по одной в час")
    }

    @Test("Последняя версия страницы остаётся всегда, сколько бы ей ни было")
    func latestAlwaysKept() {
        let ancient = calendar.date(byAdding: .day, value: -400, to: now)!
        let alsoAncient = ancient.addingTimeInterval(-3_600)
        #expect(kept([ancient, alsoAncient]) == [ancient])
        #expect(kept([ancient]) == [ancient])
    }

    @Test("Прореживание в базе: лишние версии стёрты, остальные и чужие страницы — на месте")
    func prunesStoredVersions() throws {
        let clock = ManualVersionClock()
        let mac = try VersionsTestMac(clock: clock)
        let page = try mac.page("Старая", texts: ["а"])
        let other = try mac.page("Другая", texts: ["б"])
        let content = try #require(try mac.store.pageContent(page.id))
        let otherContent = try #require(try mac.store.pageContent(other.id))
        let snapshot = PageSnapshot(page: content.page, blocks: content.blocks)
        // Пять версий 10 дней назад в одном часе и одна у другой страницы.
        let base = clock.now.addingTimeInterval(-10 * 86_400)
        for minute in 0..<5 {
            try mac.versions.save(snapshot, pageId: page.id, createdAt: base.addingTimeInterval(Double(minute) * 60),
                                  deviceName: "Mac A", summary: VersionSummary())
        }
        try mac.versions.save(PageSnapshot(page: otherContent.page, blocks: otherContent.blocks), pageId: other.id,
                              createdAt: base, deviceName: "Mac A", summary: VersionSummary())
        let pruner = VersionPruner(versions: mac.versions, store: mac.store, now: clock.reading, calendar: calendar)
        #expect(try pruner.pruneIfDue() == true)
        #expect(try mac.versionList(page.id).count == 1)
        #expect(try mac.versionList(page.id).first?.createdAt == base.addingTimeInterval(240))
        #expect(try mac.versionList(other.id).count == 1)
        #expect(try pruner.pruneIfDue() == false, "Второй раз за сутки не идёт")
        clock.advance(by: 86_400)
        #expect(try pruner.pruneIfDue() == true, "Через сутки — снова")
    }

    @Test("Удаление страницы навсегда стирает её версии и отметку")
    func eraseForeverRemovesVersions() throws {
        let mac = try VersionsTestMac()
        mac.recorder.start()
        let page = try mac.page("Уйдёт", texts: ["а"])
        let stays = try mac.page("Останется", texts: ["б"])
        mac.clock.advance(by: 6)
        #expect(try mac.versionList(page.id).count == 1)
        let block = try #require(try mac.blocks(page.id).first)
        try mac.setText("правка", ofBlock: block.id)
        #expect(try mac.versions.duePages().contains { $0.pageId == page.id })
        try mac.tree.moveToTrash(page.id)
        try mac.tree.deleteForever(page.id)
        #expect(try mac.versionList(page.id).isEmpty)
        #expect(try !mac.versions.duePages().contains { $0.pageId == page.id })
        #expect(try mac.versionList(stays.id).count == 1)
    }

    /// Строки `page_version_file`: какие файлы держит каждая версия.
    private func versionFiles(_ mac: VersionsTestMac) throws -> Set<[String]> {
        try mac.store.database.dbWriter.read { db in
            Set(try Row.fetchAll(db, sql: "SELECT versionId, fileId FROM page_version_file").map { [$0["versionId"], $0["fileId"]] })
        }
    }

    @Test("Версия держит свои файлы — обложку и файлы блоков; прореживание и удаление страницы навсегда их отпускают")
    func versionKeepsItsFiles() throws {
        let clock = ManualVersionClock()
        let mac = try VersionsTestMac(clock: clock)
        let page = try mac.page("С файлами", texts: ["а"])
        let image = AttachmentRef(name: "фото.png", byteCount: 10, contentType: "public.png", sha256: "")
        let cover = AttachmentRef(name: "обложка.jpg", byteCount: 10, contentType: "public.jpeg", sha256: "")
        try mac.updatePage(page.id) { $0.cover = PageCover(source: .file(cover)) }
        try mac.store.write { tx in
            var props = BlockProps()
            props.attachment = image
            try tx.insertBlock(Block(pageId: page.id, kind: .image, sortKey: .between(try tx.blocks(ofPage: page.id).last?.sortKey, nil),
                                     props: props))
        }
        let content = try #require(try mac.store.pageContent(page.id))
        let snapshot = PageSnapshot(page: content.page, blocks: content.blocks)
        #expect(snapshot.fileIds == [image.id, cover.id])
        let base = clock.now.addingTimeInterval(-10 * 86_400)
        let old = try mac.versions.save(snapshot, pageId: page.id, createdAt: base, deviceName: "Mac A", summary: VersionSummary())
        let last = try mac.versions.save(snapshot, pageId: page.id, createdAt: base.addingTimeInterval(60), deviceName: "Mac A",
                                         summary: VersionSummary())
        let key = { (id: UUID) in id.uuidString.lowercased() }
        #expect(try versionFiles(mac) == [[key(old.id), key(image.id)], [key(old.id), key(cover.id)],
                                          [key(last.id), key(image.id)], [key(last.id), key(cover.id)]])
        let pruner = VersionPruner(versions: mac.versions, store: mac.store, now: clock.reading, calendar: calendar)
        #expect(try pruner.pruneIfDue() == true)
        #expect(try versionFiles(mac) == [[key(last.id), key(image.id)], [key(last.id), key(cover.id)]], "Прореженная версия держит файлы")
        try mac.tree.moveToTrash(page.id)
        try mac.tree.deleteForever(page.id)
        #expect(try versionFiles(mac).isEmpty, "Стёртая навсегда страница держит файлы версиями")
    }
}
