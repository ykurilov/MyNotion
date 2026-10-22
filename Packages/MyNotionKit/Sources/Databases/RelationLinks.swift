import Foundation
import GRDB
import NotesCore

/// Лимит связи (contracts/property-types.md, Notion «Limit»): «1 страница» или «Без лимита».
public enum RelationLimit: String, Sendable, Hashable, CaseIterable {
    case one
    case none
}

/// Что с базой-целью связи — для настройки «Связана с».
public enum RelationTargetState: Sendable, Hashable {
    case available(title: String)
    /// База в корзине (сама или со страницей-хозяином): её строки в связях не видны.
    case trashed
    /// База стёрта навсегда: ячейки пустые, в настройке «база удалена» (spec, Edge Cases).
    case erased
    /// Связь ещё не настроена.
    case missing
}

extension DatabaseProperty {
    public var relationLimit: RelationLimit {
        config["limit"]?.string.flatMap(RelationLimit.init(rawValue:)) ?? .none
    }
}

/// Чтение связей (data-model.md, `db_relation_link`, research R7): у двусторонней пары связи хранятся у свойства с
/// меньшим id, второе читает их по колонке цели. Связанная строка видна, если она и её база не в корзине.
public enum RelationLinks {
    /// Где лежат связи свойства: свойство записи и `reversed` — строки этого свойства в колонке `targetRowId`.
    public static func storage(of property: DatabaseProperty) -> (propertyId: UUID, reversed: Bool) {
        guard let paired = property.pairedRelation, paired.uuidString < property.id.uuidString else { return (property.id, false) }
        return (paired, true)
    }

    /// Запись связи строки `rowId` свойства `property` со строкой `targetRowId` (в любом направлении хранения).
    static func linkId(_ rowId: UUID, through property: DatabaseProperty, to targetRowId: UUID) -> UUID {
        let storage = storage(of: property)
        return storage.reversed ? RelationLink.id(propertyId: storage.propertyId, rowId: targetRowId, targetRowId: rowId)
            : RelationLink.id(propertyId: storage.propertyId, rowId: rowId, targetRowId: targetRowId)
    }

    /// Связанные строки у строк `rows` по порядку связей: только живые строки живой базы-цели.
    public static func targets(of rows: [UUID], through property: DatabaseProperty, in db: Database) throws -> [UUID: [RelatedRow]] {
        guard !rows.isEmpty, let target = property.relationTarget, try !isInTrash(target, in: db) else { return [:] }
        let storage = storage(of: property)
        let (own, other) = storage.reversed ? ("targetRowId", "rowId") : ("rowId", "targetRowId")
        var result: [UUID: [RelatedRow]] = [:]
        for start in stride(from: 0, to: rows.count, by: 500) {
            let chunk = rows[start..<min(start + 500, rows.count)]
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT l.\(own), t.id, t.title, t.icon FROM db_relation_link l JOIN page t ON t.id = l.\(other)
                WHERE l.propertyId = ? AND l.\(own) IN (\(marks)) AND l.isPresent = 1 AND t.trashedAt IS NULL AND t.parentId = ?
                ORDER BY l.sortKey, l.id
                """, arguments: StatementArguments([storage.propertyId.databaseText] + chunk.map(\.databaseText) + [target.databaseText]))
            while let row = try cursor.next() {
                guard let rowId = UUID(uuidString: row[0]), let targetId = UUID(uuidString: row[1]) else { continue }
                result[rowId, default: []].append(RelatedRow(id: targetId, title: row[2], icon: row[3]))
            }
        }
        return result
    }

    /// Связанные строки одной строки (окно связи: «N выбрано»).
    public static func related(_ rowId: UUID, through property: DatabaseProperty, in store: NotesStore) throws -> [RelatedRow] {
        try store.database.dbWriter.read { db in try targets(of: [rowId], through: property, in: db)[rowId] ?? [] }
    }

    /// Строки базы-цели для окна связи: по названию без учёта регистра и диакритики, без корзины и шаблонов, по порядку
    /// страниц; не больше `limit`.
    public static func candidates(for property: DatabaseProperty, matching query: String, limit: Int = 50, in store: NotesStore) throws -> [RelatedRow] {
        guard let target = property.relationTarget else { return [] }
        let needle = SortableText.make(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return try store.database.dbWriter.read { db in
            guard try !isInTrash(target, in: db) else { return [] }
            var found: [RelatedRow] = []
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT id, title, icon FROM page WHERE parentId = ? AND trashedAt IS NULL AND isTemplate = 0 ORDER BY sortKey, id
                """, arguments: [target.databaseText])
            while found.count < limit, let row = try cursor.next() {
                let title: String = row[1]
                guard needle.isEmpty || SortableText.make(title).contains(needle), let id = UUID(uuidString: row[0]) else { continue }
                found.append(RelatedRow(id: id, title: title, icon: row[2]))
            }
            return found
        }
    }

    /// База-цель связи для настройки «Связана с».
    public static func targetState(of property: DatabaseProperty, in store: NotesStore) throws -> RelationTargetState {
        guard let target = property.relationTarget else { return .missing }
        return try store.database.dbWriter.read { db in
            guard let title = try String.fetchOne(db, sql: "SELECT title FROM page WHERE id = ?", arguments: [target.databaseText]) else { return .erased }
            return try isInTrash(target, in: db) ? .trashed : .available(title: title)
        }
    }

    /// Страница или кто-то из её родителей в корзине (или страницы уже нет).
    static func isInTrash(_ pageId: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: """
            WITH RECURSIVE up(id, parentId, trashedAt, depth) AS (
                SELECT id, parentId, trashedAt, 0 FROM page WHERE id = ?
                UNION ALL SELECT p.id, p.parentId, p.trashedAt, up.depth + 1 FROM page p JOIN up ON p.id = up.parentId WHERE up.depth < 64
            )
            SELECT NOT EXISTS (SELECT 1 FROM up) OR EXISTS (SELECT 1 FROM up WHERE trashedAt IS NOT NULL)
            """), arguments: [pageId.databaseText]) ?? true
    }
}

extension RelationLinks {
    /// Базы для «Связана с»: вне корзины, по названию; своя — первой.
    public static func databases(besides databaseId: UUID, in store: NotesStore) throws -> [RelatedRow] {
        try store.database.dbWriter.read { db in
            let all = try Row.fetchAll(db, sql: """
                SELECT p.id, p.title, p.icon FROM db_database d JOIN page p ON p.id = d.pageId WHERE p.trashedAt IS NULL
                """).compactMap { row -> RelatedRow? in
                guard let id = UUID(uuidString: row[0]) else { return nil }
                return RelatedRow(id: id, title: row[1], icon: row[2])
            }
            let alive = try all.filter { try !isInTrash($0.id, in: db) }
            let own = alive.filter { $0.id == databaseId }
            return own + alive.filter { $0.id != databaseId }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}
