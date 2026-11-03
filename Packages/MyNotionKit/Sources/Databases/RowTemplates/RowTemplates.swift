import Foundation
import GRDB
import NotesCore

/// Шаблон строки базы (spec US6, research R13): страница-ребёнок базы с отметкой `isTemplate`. В таблице, дереве, поиске
/// и окне связи его нет; виден только в «Создать ▾» своей базы.
public struct RowTemplate: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let title: String
    public let icon: String?
}

/// Шаблоны базы по порядку и шаблон по умолчанию (`nil` — «Пустая»).
public struct RowTemplateList: Sendable, Hashable {
    public var templates: [RowTemplate] = []
    public var defaultTemplateId: UUID?
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

/// Копия шаблонов строк одной базы в другую («Дублировать» базу): свойства, варианты и строки — по таблице замены
/// `idMap` (старый id → новый), метка по умолчанию — на копию своего шаблона. Даты остаются относительными.
public enum RowTemplateCopier {
    /// Возвращает id шаблона → id его копии.
    @discardableResult
    public static func copyTemplates(from sourceId: UUID, to targetId: UUID, idMap: [UUID: UUID],
                                     in transaction: NotesTransaction) throws -> [UUID: UUID] {
        let texts = Dictionary(idMap.map { ($0.key.databaseText, $0.value.databaseText) }, uniquingKeysWith: { first, _ in first })
        let uniqueId = try UniqueIds.property(ofDatabase: sourceId, in: transaction)?.id
        let relations = try transaction.properties(ofDatabase: sourceId).filter { $0.kind == .relation }
        var lastKey = try transaction.allPages().filter { $0.parentId == targetId }.map(\.sortKey).max()
        var copies: [UUID: UUID] = [:]
        for template in try RowTemplates.templates(of: sourceId, transaction) {
            let sortKey = FractionalSortKey.between(lastKey, nil)
            lastKey = sortKey
            let copyId = try PageBranchCopier.copy(template.id, in: transaction, title: template.title, parentId: targetId, sortKey: sortKey,
                                                   resolvesTemplateDates: false, rootIsTemplate: true).rootId
            for cell in try transaction.cells(ofRow: template.id) where cell.propertyId != uniqueId {
                guard let value = cell.value, let propertyId = idMap[cell.propertyId] else { continue }
                try transaction.setCell(rowId: copyId, propertyId: propertyId, value: remapped(value, texts))
            }
            for relation in relations {
                guard let mappedId = idMap[relation.id], let mapped = try transaction.property(mappedId) else { continue }
                for target in try RelationLinks.targets(of: [template.id], through: relation, in: transaction.database)[template.id] ?? [] {
                    let targetRow = idMap[target.id] ?? target.id
                    _ = try DatabaseOperations.writeLinks(try DatabaseOperations.linkStates(copyId, mapped, targetRow, transaction), transaction)
                }
            }
            copies[template.id] = copyId
        }
        if let defaultId = try RowTemplates.defaultTemplate(of: sourceId, transaction), let copy = copies[defaultId],
           var schema = try transaction.database(targetId) {
            schema.defaultTemplateId = copy
            try transaction.saveDatabase(schema)
        }
        return copies
    }

    /// Значение ячейки с id вариантов и строк, заменёнными по таблице.
    static func remapped(_ value: JSONValue, _ texts: [String: String]) -> JSONValue {
        switch value {
        case .string(let text): .string(texts[text] ?? text)
        case .array(let items): .array(items.map { remapped($0, texts) })
        case .object(let fields): .object(fields.mapValues { remapped($0, texts) })
        default: value
        }
    }
}
