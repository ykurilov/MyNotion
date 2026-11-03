import Foundation
import GRDB
import NotesCore

/// Базы в операциях дерева (T102, spec Edge Cases): «Дублировать» базу или страницу со встроенной базой и «Переместить в»
/// для строк. Пишет записи баз в транзакции самой операции — их видят поиск, формулы и синхронизация, а ⌘Z операции
/// отменяет и их: копия стирается вместе с записями, перенос назад возвращает строку к её прежним значениям.
public struct DatabaseTreeAddon: PageTreeAddon {
    public init() {}

    // MARK: Копия базы

    /// Каждая скопированная база получает схему, варианты, виды, значения строк (и шаблонов строк), связи и ручной порядок
    /// со своими id. Связь с базой вне ветки — односторонняя на те же строки; связь внутри ветки (в том числе с собой) —
    /// на строки копии. У дат копии напоминания выключены, как у дат в тексте.
    public func branchCopied(_ copy: PageBranchCopier.Result, in transaction: NotesTransaction) throws {
        let databases = try copy.pageIds.keys.filter { try transaction.isDatabase($0) }.sorted { $0.uuidString < $1.uuidString }
        guard !databases.isEmpty else { return }
        var ids = IdRemap(pages: copy.pageIds)
        var schemas: [UUID: (properties: [DatabaseProperty], views: [DatabaseView])] = [:]
        for databaseId in databases {
            ids.matchInsideText(databaseId)
            let properties = try transaction.properties(ofDatabase: databaseId)
            let views = try transaction.views(ofDatabase: databaseId)
            for property in properties {
                ids.add(property.id)
                for option in try transaction.options(ofProperty: property.id) { ids.add(option.id) }
            }
            for view in views { ids.add(view.id) }
            schemas[databaseId] = (properties, views)
        }
        for databaseId in databases {
            try copyDatabase(databaseId, schema: schemas[databaseId]!, copy: copy, ids: ids, in: transaction)
        }
    }

    private func copyDatabase(_ databaseId: UUID, schema: (properties: [DatabaseProperty], views: [DatabaseView]),
                              copy: PageBranchCopier.Result, ids: IdRemap, in transaction: NotesTransaction) throws {
        guard let original = try transaction.database(databaseId), let newDatabaseId = copy.pageIds[databaseId] else { return }
        // Шаблоны строк (US6): их страницы копирует `PageBranchCopier` вместе со строками, значения — цикл по строкам ниже.
        // Своё для шаблонов при копии базы (шаблон по умолчанию и прочее) — здесь.
        try transaction.saveDatabase(DatabaseSchema(pageId: newDatabaseId, isInline: original.isInline,
                                                    defaultTemplateId: original.defaultTemplateId.flatMap { copy.pageIds[$0] }))

        var copiedProperties: [(original: DatabaseProperty, copy: DatabaseProperty)] = []
        for property in schema.properties {
            var config = property.config
            // Пара связи остаётся парой, только если скопировано и ответное свойство.
            if let paired = property.pairedRelation, ids[paired] == nil { config["pairedPropertyId"] = nil }
            let saved = try transaction.saveProperty(DatabaseProperty(
                id: ids[property.id]!, databaseId: newDatabaseId, name: property.name, kind: property.kind,
                config: ids.schemaJSON(config), sortKey: property.sortKey))
            copiedProperties.append((property, saved))
            for option in try transaction.options(ofProperty: property.id) {
                try transaction.saveOption(SelectOption(id: ids[option.id]!, propertyId: saved.id, name: option.name, colorName: option.color,
                                                        sortKey: option.sortKey, statusGroup: option.statusGroup, deletedAt: nil,
                                                        fieldClocks: .init()))
            }
        }
        for view in schema.views {
            try transaction.saveView(DatabaseView(
                id: ids[view.id]!, databaseId: newDatabaseId, name: view.name, type: view.type, sortKey: view.sortKey,
                filter: view.filter.map(ids.schemaJSON), sorts: ids.schemaJSON(view.sorts), columns: ids.schemaJSON(view.columns),
                group: view.group.map(ids.schemaJSON), layoutOptions: ids.schemaJSON(view.layoutOptions)))
        }

        let rows = try copy.pageIds.keys.filter { try transaction.page($0)?.parentId == databaseId }
        for row in rows {
            let newRow = copy.pageIds[row]!
            for cell in try transaction.cells(ofRow: row) {
                guard var value = cell.value, let pair = copiedProperties.first(where: { $0.original.id == cell.propertyId }) else { continue }
                value = ids.wholeValues(value)
                if pair.copy.kind == .date { value["reminder"] = nil }
                try transaction.setCell(rowId: newRow, propertyId: pair.copy.id, value: value)
            }
        }
        for pair in copiedProperties where pair.original.kind == .relation {
            let targetCopied = pair.original.relationTarget.map { copy.pageIds[$0] != nil } ?? false
            for link in try Self.links(through: pair.original, in: transaction) {
                guard let newRow = copy.pageIds[link.rowId] else { continue }
                let target = copy.pageIds[link.targetRowId] ?? (targetCopied ? nil : link.targetRowId)
                guard let target else { continue }
                try Self.saveLink(newRow, through: pair.copy, to: target, sortKey: link.sortKey, in: transaction)
            }
        }
        for view in schema.views {
            for order in try Row.fetchAll(transaction.database, sql: "SELECT rowId, sortKey FROM db_row_order WHERE viewId = ?",
                                          arguments: [view.id.databaseText]) {
                guard let rowId = UUID(uuidString: order[0]), let newRow = copy.pageIds[rowId],
                      let key = FractionalSortKey(rawValue: order[1]) else { continue }
                try transaction.setRowOrder(viewId: ids[view.id]!, rowId: newRow, sortKey: key)
            }
        }
    }

    // MARK: Перенос строки

    /// Страница пришла в базу — строка: значения свойств с тем же названием и типом переходят из прежней базы (вариант —
    /// по названию, нет такого — создаётся), связь — если ведёт в ту же базу; остальные значения остаются при строке
    /// скрытыми и возвращаются, когда строка вернётся (⌘Z). Номер ID — следующий в новой базе, если его ещё нет.
    /// Правки с другого Mac не трогаются: там это уже сделано.
    public func pageMoved(_ pageId: UUID, from oldParentId: UUID?, to newParentId: UUID?, in transaction: NotesTransaction) throws {
        guard transaction.replicatedFromDeviceName == nil, let newParentId, try transaction.isDatabase(newParentId),
              let page = try transaction.page(pageId), !page.isTemplate else { return }
        let targets = try transaction.properties(ofDatabase: newParentId)
        if let oldParentId, try transaction.isDatabase(oldParentId) {
            for source in try transaction.properties(ofDatabase: oldParentId) where source.kind != .uniqueId {
                guard let target = targets.first(where: { $0.name == source.name && $0.kind == source.kind }) else { continue }
                if source.kind == .relation {
                    guard source.relationTarget == target.relationTarget else { continue }
                    for link in try Self.links(of: pageId, through: source, in: transaction) {
                        try Self.saveLink(pageId, through: target, to: link.targetRowId, sortKey: link.sortKey, in: transaction)
                    }
                } else if source.kind.storesCells, let value = try transaction.cell(rowId: pageId, propertyId: source.id)?.value {
                    let adopted = try Self.adoptOptions(value, from: source, to: target, in: transaction)
                    if try transaction.cell(rowId: pageId, propertyId: target.id)?.value != adopted {
                        try transaction.setCell(rowId: pageId, propertyId: target.id, value: adopted)
                    }
                }
            }
        }
        if let uniqueId = targets.first(where: { $0.kind == .uniqueId }), try transaction.cell(rowId: pageId, propertyId: uniqueId.id)?.value == nil {
            try UniqueIds.assign(toRow: pageId, ofDatabase: newParentId, in: transaction)
        }
    }

    /// «Переместить в» строку не в базу: её свойства пропадут из вида — окно спрашивает подтверждение.
    public static func movingLosesProperties(_ pageId: UUID, to parentId: UUID?, in store: NotesStore) throws -> Bool {
        try store.database.dbWriter.read { db in
            let isDatabase = { (id: UUID) in try Bool.fetchOne(db, sql: "SELECT 1 FROM db_database WHERE pageId = ?", arguments: [id.databaseText]) ?? false }
            guard let currentParent = try String.fetchOne(db, sql: "SELECT parentId FROM page WHERE id = ?", arguments: [pageId.databaseText])
                .flatMap(UUID.init(uuidString:)), try isDatabase(currentParent) else { return false }
            return try !(parentId.map(isDatabase) ?? false)
        }
    }

    /// Варианты выбора — по названию: в новой базе берётся вариант с тем же названием, нет — создаётся с тем же цветом.
    private static func adoptOptions(_ value: JSONValue, from source: DatabaseProperty, to target: DatabaseProperty,
                                     in transaction: NotesTransaction) throws -> JSONValue {
        guard [.select, .multiSelect, .status].contains(source.kind) else { return value }
        let sourceOptions = try transaction.options(ofProperty: source.id)
        func adopt(_ id: JSONValue) throws -> JSONValue? {
            guard let option = sourceOptions.first(where: { $0.id.databaseText == id.string?.lowercased() }) else { return nil }
            let existing = try transaction.options(ofProperty: target.id)
            if let match = existing.first(where: { $0.name == option.name }) { return .string(match.id.databaseText) }
            let created = try transaction.saveOption(SelectOption(
                id: .timeOrdered(), propertyId: target.id, name: option.name, colorName: option.color,
                sortKey: .between(existing.map(\.sortKey).max(), nil), statusGroup: option.statusGroup, deletedAt: nil, fieldClocks: .init()))
            return .string(created.id.databaseText)
        }
        if let ids = value.array { return .array(try ids.compactMap(adopt)) }
        return try adopt(value) ?? value
    }

    // MARK: Связи

    /// Живые связи свойства в виде «строка этого свойства → строка цели», как бы они ни хранились.
    private static func links(through property: DatabaseProperty, in transaction: NotesTransaction) throws
        -> [(rowId: UUID, targetRowId: UUID, sortKey: FractionalSortKey)] {
        let storage = RelationLinks.storage(of: property)
        return try Row.fetchAll(transaction.database, sql: """
            SELECT rowId, targetRowId, sortKey FROM db_relation_link WHERE propertyId = ? AND isPresent = 1 ORDER BY sortKey, id
            """, arguments: [storage.propertyId.databaseText]).compactMap { row in
            guard let rowId = UUID(uuidString: row[0]), let targetRowId = UUID(uuidString: row[1]),
                  let key = FractionalSortKey(rawValue: row[2]) else { return nil }
            return storage.reversed ? (targetRowId, rowId, key) : (rowId, targetRowId, key)
        }
    }

    /// Живые связи одной строки свойства.
    private static func links(of rowId: UUID, through property: DatabaseProperty, in transaction: NotesTransaction) throws
        -> [(targetRowId: UUID, sortKey: FractionalSortKey)] {
        let storage = RelationLinks.storage(of: property)
        return storage.reversed
            ? try transaction.relationLinks(propertyId: storage.propertyId, targetRowId: rowId).map { ($0.rowId, $0.sortKey) }
            : try transaction.relationLinks(propertyId: storage.propertyId, rowId: rowId).map { ($0.targetRowId, $0.sortKey) }
    }

    private static func saveLink(_ rowId: UUID, through property: DatabaseProperty, to targetRowId: UUID, sortKey: FractionalSortKey,
                                 in transaction: NotesTransaction) throws {
        let storage = RelationLinks.storage(of: property)
        let (from, to) = storage.reversed ? (targetRowId, rowId) : (rowId, targetRowId)
        let existing = try transaction.relationLink(RelationLink.id(propertyId: storage.propertyId, rowId: from, targetRowId: to))
        guard existing?.isPresent != true else { return }
        var link = existing ?? RelationLink(propertyId: storage.propertyId, rowId: from, targetRowId: to, sortKey: sortKey)
        link.isPresent = true
        link.sortKey = sortKey
        try transaction.saveRelationLink(link)
    }
}

/// id оригинала → id копии. В настройках свойств и видов id встречаются и внутри строк (формула `prop("…")`) — там
/// заменяются id схемы и баз (строк в настройках внутри текста нет, а их тысячи); строки целиком — любые id.
private struct IdRemap {
    private var ids: [UUID: UUID]
    private var schemaTexts: [(String, String)] = []

    init(pages: [UUID: UUID]) {
        ids = pages
    }

    mutating func matchInsideText(_ pageId: UUID) {
        if let new = ids[pageId] { addText(pageId, new) }
    }

    subscript(id: UUID) -> UUID? { ids[id] }

    mutating func add(_ id: UUID) {
        let new = UUID.timeOrdered()
        ids[id] = new
        addText(id, new)
    }

    private mutating func addText(_ old: UUID, _ new: UUID) {
        schemaTexts.append((old.databaseText, new.databaseText))
        schemaTexts.append((old.uuidString, new.uuidString))
    }

    func schemaJSON(_ value: JSONValue) -> JSONValue {
        map(value) { text in
            guard text.count >= 36 else { return text }
            if let id = UUID(uuidString: text), let new = ids[id] { return text == id.uuidString ? new.uuidString : new.databaseText }
            var result = text
            for (old, new) in schemaTexts where result.contains(old) { result = result.replacingOccurrences(of: old, with: new) }
            return result
        }
    }

    func wholeValues(_ value: JSONValue) -> JSONValue {
        map(value) { text in
            guard text.count == 36, let id = UUID(uuidString: text), let new = ids[id] else { return text }
            return text == id.uuidString ? new.uuidString : new.databaseText
        }
    }

    private func map(_ value: JSONValue, _ text: (String) -> String) -> JSONValue {
        switch value {
        case .string(let string): .string(text(string))
        case .array(let items): .array(items.map { map($0, text) })
        case .object(let object): .object(object.mapValues { map($0, text) })
        case .null, .bool, .number: value
        }
    }
}
