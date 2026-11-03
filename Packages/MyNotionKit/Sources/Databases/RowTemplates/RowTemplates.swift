import Foundation
import GRDB
import NotesCore

/// Шаблон строки базы (spec US6, research R13): страница-ребёнок базы с отметкой `isTemplate`. В таблице, дереве, поиске
/// и окне связи его нет; виден только в «Создать ▾» своей базы.
public struct RowTemplate: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let icon: String?

    public init(id: UUID, title: String, icon: String?) {
        self.id = id
        self.title = title
        self.icon = icon
    }
}

/// Шаблоны базы по порядку и шаблон по умолчанию (`nil` — «Пустая»).
public struct RowTemplateList: Sendable, Hashable {
    public var templates: [RowTemplate] = []
    public var defaultTemplateId: UUID?

    public init(templates: [RowTemplate] = [], defaultTemplateId: UUID? = nil) {
        self.templates = templates
        self.defaultTemplateId = defaultTemplateId
    }
}

/// По какому шаблону делать новую строку.
public enum RowTemplateChoice: Sendable, Hashable {
    /// Шаблон по умолчанию базы («Создать», «+ Новая строка»); нет его — пустая строка.
    case databaseDefault
    /// «Пустая».
    case empty
    case template(UUID)
}

public enum RowTemplates {
    /// Живые шаблоны базы и шаблон по умолчанию, если он среди них.
    public static func list(of databaseId: UUID, in store: NotesStore) throws -> RowTemplateList {
        try store.database.dbWriter.read { db in
            let templates = try Row.fetchAll(db, sql: """
                SELECT id, title, icon FROM page WHERE parentId = ? AND isTemplate = 1 AND trashedAt IS NULL ORDER BY sortKey, id
                """, arguments: [databaseId.databaseText]).compactMap { row -> RowTemplate? in
                UUID(uuidString: row["id"]).map { RowTemplate(id: $0, title: row["title"], icon: row["icon"]) }
            }
            let defaultId = try String.fetchOne(db, sql: "SELECT defaultTemplateId FROM db_database WHERE pageId = ?",
                                                arguments: [databaseId.databaseText]).flatMap(UUID.init(uuidString:))
            return RowTemplateList(templates: templates, defaultTemplateId: templates.contains { $0.id == defaultId } ? defaultId : nil)
        }
    }

    /// Живые шаблоны базы по порядку в открытой транзакции.
    static func templates(of databaseId: UUID, _ transaction: NotesTransaction) throws -> [Page] {
        try transaction.allPages().filter { $0.parentId == databaseId && $0.isTemplate && $0.trashedAt == nil }
            .sorted { ($0.sortKey, $0.id.uuidString) < ($1.sortKey, $1.id.uuidString) }
    }

    /// Шаблон `templateId` живой и принадлежит базе `databaseId`.
    static func requireTemplate(_ templateId: UUID, of databaseId: UUID?, _ transaction: NotesTransaction) throws -> Page {
        guard let template = try transaction.page(templateId) else { throw NotesStoreError.pageNotFound(templateId) }
        guard template.isTemplate, template.trashedAt == nil, databaseId == nil || template.parentId == databaseId else {
            throw NotesStoreError.invalidRecord("это не шаблон строки этой базы")
        }
        return template
    }

    /// Шаблон по умолчанию базы, если он ещё живой.
    static func defaultTemplate(of databaseId: UUID, _ transaction: NotesTransaction) throws -> UUID? {
        guard let id = try transaction.database(databaseId)?.defaultTemplateId,
              let template = try transaction.page(id), template.isTemplate, template.trashedAt == nil, template.parentId == databaseId
        else { return nil }
        return id
    }
}
