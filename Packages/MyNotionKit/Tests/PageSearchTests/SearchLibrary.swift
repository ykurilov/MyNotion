import Foundation
import GRDB
@testable import NotesCore
@testable import PageSearch

/// Временная база с подключённым индексом поиска; стирается вместе с объектом.
final class SearchLibrary {
    let store: NotesStore
    private let folder: TemporaryFolder?

    init() throws {
        let folder = try TemporaryFolder()
        self.folder = folder
        let database = try AppDatabase.open(at: folder.databaseURL)
        store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(SearchIndexer())
    }

    init(store: NotesStore) {
        folder = nil
        self.store = store
        store.addWriteHook(SearchIndexer())
    }

    deinit {
        if folder != nil { store.database.close() }
    }

    /// Страница с блоками-абзацами; без блоков остаётся один пустой абзац.
    @discardableResult
    func page(_ title: String, icon: String? = nil, parent: UUID? = nil, blocks: [String] = []) throws -> Page {
        try store.write { transaction in
            let page = try transaction.createPage(title: title, icon: icon, parentId: parent)
            var previous: FractionalSortKey?
            if !blocks.isEmpty, let empty = try transaction.blocks(ofPage: page.id).first {
                try transaction.deleteBlock(empty.id)
            }
            for text in blocks {
                let key = FractionalSortKey.between(previous, nil)
                try transaction.insertBlock(Block(pageId: page.id, text: InlineText(text), sortKey: key))
                previous = key
            }
            return page
        }
    }

    func search(_ query: String) throws -> [PageSearchResult] {
        try PageSearch(store: store).results(for: query, in: PageTreeSnapshot(allPages: store.pageOutline()))
    }

    func foundPageIds(_ query: String) throws -> [UUID] {
        try search(query).map(\.pageId)
    }

    func indexRowCount(ofPage pageId: UUID) throws -> Int {
        try store.database.dbWriter.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM search_index WHERE pageId = ?", arguments: [pageId.databaseText]) ?? 0
        }
    }

    /// Все строки индекса: rowid, страница, блок, текст — для сравнения двух способов наполнения.
    func indexRows() throws -> [[String?]] {
        try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT rowid, pageId, blockId, content FROM search_index ORDER BY rowid").map { row in
                [String(row[0] as Int64), row[1], row[2], row[3]]
            }
        }
    }
}

/// Пустая папка на время теста; стирается вместе с объектом.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotionSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var databaseURL: URL { url.appendingPathComponent("MyNotion.sqlite") }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

struct DeliberateFailure: Error {}
