import Foundation
import GRDB
import Testing
@testable import NotesCore

/// Запросы разделов «Избранное» и «Недавние» (research R4, contracts/page-operations.md).
@Suite("Избранное и недавние: запросы")
struct FavoritesRecentsQueryTests {
    let folder: TemporaryFolder
    let store: NotesStore

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
    }

    @discardableResult
    private func page(_ title: String, parent: UUID? = nil, _ change: (inout Page) -> Void = { _ in }) throws -> Page {
        try store.write { tx in
            var page = try tx.createPage(title: title, parentId: parent)
            change(&page)
            return try tx.updatePage(page)
        }
    }

    @Test("Избранное — по ключу порядка, без страниц в корзине и без их подстраниц; шаблон остаётся")
    func favoritesByKeyWithoutTrash() throws {
        let c = try page("C") { $0.favorite = FractionalSortKey(rawValue: "c") }
        let a = try page("A") { $0.favorite = FractionalSortKey(rawValue: "a") }
        let template = try page("Шаблон") { $0.favorite = FractionalSortKey(rawValue: "b"); $0.isTemplate = true }
        try page("Не в избранном")
        let trashed = try page("В корзине") { $0.favorite = FractionalSortKey(rawValue: "d") }
        try page("Подстраница в корзине", parent: trashed.id) { $0.favorite = FractionalSortKey(rawValue: "e") }
        try store.write { tx in
            var page = try #require(try tx.page(trashed.id))
            page.trashedAt = Date()
            try tx.updatePage(page)
        }
        #expect(try store.favoritePages().map(\.id) == [a.id, template.id, c.id])
    }

    @Test("Недавние — по visitedAt, свежая сверху; без корзины и шаблонов; лимит 5 и 50")
    func recentsByVisit() throws {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        var visited: [Page] = []
        for index in 0..<60 {
            visited.append(try page("Страница \(index)") { $0.visitedAt = base.addingTimeInterval(Double(index)) })
        }
        try page("Не открывалась")
        let template = try page("Шаблон") { $0.visitedAt = base.addingTimeInterval(1_000); $0.isTemplate = true }
        try page("Подстраница шаблона", parent: template.id) { $0.visitedAt = base.addingTimeInterval(1_001) }
        let trashed = try page("В корзине") { $0.visitedAt = base.addingTimeInterval(2_000) }
        try page("Подстраница в корзине", parent: trashed.id) { $0.visitedAt = base.addingTimeInterval(2_001) }
        try store.write { tx in
            var page = try #require(try tx.page(trashed.id))
            page.trashedAt = Date()
            try tx.updatePage(page)
        }
        let newestFirst = visited.reversed().map(\.id)
        #expect(try store.recentPages(limit: 5).map(\.id) == Array(newestFirst.prefix(5)))
        #expect(try store.recentPages(limit: 50).map(\.id) == Array(newestFirst.prefix(50)))
    }

    @Test("Запросы идут по индексам page_by_favorite и page_by_visit")
    func queriesUseIndexes() throws {
        let plans = try store.database.dbWriter.read { db in
            (try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + NotesStore.favoritesQuery).map { $0["detail"] as String },
             try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + NotesStore.recentsQuery, arguments: [5]).map { $0["detail"] as String })
        }
        #expect(plans.0.contains { $0.contains("page_by_favorite") }, "\(plans.0)")
        #expect(plans.1.contains { $0.contains("page_by_visit") }, "\(plans.1)")
        #expect(!plans.0.contains { $0.contains("USE TEMP B-TREE FOR ORDER BY") }, "порядок — из индекса: \(plans.0)")
        #expect(!plans.1.contains { $0.contains("USE TEMP B-TREE FOR ORDER BY") }, "порядок — из индекса: \(plans.1)")
    }
}
