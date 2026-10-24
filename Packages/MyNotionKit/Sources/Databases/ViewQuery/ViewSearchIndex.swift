import Foundation
import GRDB
import NotesCore

/// Поиск в базе на каждый символ (US3, ≤ 50 мс на символ): текст строк для поиска читается один раз, когда открыли
/// поле; дальше каждый символ сужает уже готовый итог вида без запроса к базе. Что ищется — как у запроса SQL
/// (`ViewQuerySQL.searchPredicate`): название, текст, ссылка, email, телефон, итоги формул и сводок, названия вариантов,
/// имена файлов — у видимых свойств; без регистра и «ё».
public struct ViewSearchIndex: Sendable {
    /// Сравнимые тексты строки через разделитель (поиск не перескакивает из значения в значение) — байтами UTF-8:
    /// тексты уже приведены (`SortableText`), сравнение байтов `memmem` в десятки раз быстрее `String.contains`.
    let texts: [UUID: [UInt8]]
    static let separator = "\u{1}"

    public static func build(view: DatabaseView, catalog: DatabaseCatalog, in db: Database) throws -> ViewSearchIndex {
        var parts: [UUID: [String]] = [:]
        let properties = ViewQuery.visiblePropertyIds(of: view, catalog: catalog).compactMap { catalog.propertiesById[$0] }
            + [catalog.titleProperty].compactMap { $0 }
        func each(_ sql: String, _ arguments: StatementArguments, _ body: (UUID, String) -> Void) throws {
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try cursor.next() {
                if let id = UUID(uuidString: row[0]), let text: String = row[1], !text.isEmpty { body(id, text) }
            }
        }
        var seen: Set<UUID> = []
        for property in properties where seen.insert(property.id).inserted {
            let id = property.id.databaseText
            switch property.kind {
            case .text, .url, .email, .phone:
                try each("SELECT rowId, sortText FROM db_cell WHERE propertyId = ? AND sortText IS NOT NULL", [id]) { parts[$0, default: []].append($1) }
            case .title, .formula, .rollup:
                try each("SELECT rowId, sortText FROM db_computed WHERE propertyId = ? AND sortText IS NOT NULL", [id]) { parts[$0, default: []].append($1) }
            case .select, .status, .multiSelect:
                let names = Dictionary(uniqueKeysWithValues: (catalog.options[property.id] ?? []).map { ($0.id.databaseText, SortableText.make($0.name)) })
                try each("SELECT rowId, sortText FROM db_cell WHERE propertyId = ? AND sortText IS NOT NULL", [id]) { row, ids in
                    for option in ids.split(separator: " ") { if let name = names[String(option)] { parts[row, default: []].append(name) } }
                }
            case .files:
                try each("SELECT rowId, searchText FROM db_cell WHERE propertyId = ? AND searchText IS NOT NULL", [id]) { parts[$0, default: []].append($1) }
            default:
                break
            }
        }
        return ViewSearchIndex(texts: parts.mapValues { Array($0.joined(separator: separator).utf8) })
    }

    public func matches(_ rowId: UUID, needle: String) -> Bool {
        var needle = needle
        return needle.withUTF8 { matches(rowId, bytes: $0) }
    }

    func matches(_ rowId: UUID, bytes needle: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let text = texts[rowId] else { return false }
        return text.withUnsafeBytes { memmem($0.baseAddress, $0.count, needle.baseAddress, needle.count) != nil }
    }

    /// Итог вида без поиска, суженный поиском: порядок и группы — те же, у групп — только найденные строки.
    public func filter(_ presentation: ViewPresentation, search: String) -> ViewPresentation {
        let needle = SortableText.make(search.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return presentation }
        var result = presentation
        var bytes = needle
        result.rowIds = bytes.withUTF8 { needle in presentation.rowIds.filter { matches($0, bytes: needle) } }
        let found = Set(result.rowIds)
        result.groups = presentation.groups?.map { group in
            var group = group
            group.rowIds = group.rowIds.filter(found.contains)
            return group
        }
        return result
    }
}

extension ViewQuery {
    /// Вид без поиска и текст строк для поиска — одним чтением (поле поиска открыли).
    public static func searchBase(_ viewId: UUID, in store: NotesStore, now: Date = Date()) throws
        -> (presentation: ViewPresentation, index: ViewSearchIndex)? {
        try store.database.dbWriter.read { db in
            guard let view = try Row.fetchOne(db, sql: "SELECT * FROM db_view WHERE id = ?", arguments: [viewId.databaseText])
                .map(DatabaseView.init(row:)) else { return nil }
            let catalog = try DatabaseCatalog.read(view.databaseId, in: db)
            return (presentation: try present(view, catalog: catalog, search: nil, now: now, in: db),
                    index: try ViewSearchIndex.build(view: view, catalog: catalog, in: db))
        }
    }
}
