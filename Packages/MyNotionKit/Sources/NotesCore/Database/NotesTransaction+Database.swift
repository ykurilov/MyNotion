import Foundation
import GRDB

/// Записи баз в транзакции ядра (data-model.md): каждая правка — новая метка изменённым полям и строка в
/// `NotesChanges.database`. Логики типов здесь нет: её добавляет модуль `Databases`.
extension NotesTransaction {
    // MARK: Чтение

    public func database(_ pageId: UUID) throws -> DatabaseSchema? {
        try Row.fetchOne(database, sql: "SELECT * FROM db_database WHERE pageId = ?", arguments: [pageId.databaseText])
            .map(DatabaseSchema.init(row:))
    }

    /// Страница — база.
    public func isDatabase(_ pageId: UUID) throws -> Bool {
        try Bool.fetchOne(database.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM db_database WHERE pageId = ?)"),
                          arguments: [pageId.databaseText]) ?? false
    }

    public func properties(ofDatabase databaseId: UUID, includingDeleted: Bool = false) throws -> [DatabaseProperty] {
        let sql = "SELECT * FROM db_property WHERE databaseId = ?" + (includingDeleted ? "" : " AND deletedAt IS NULL") + " ORDER BY sortKey, id"
        return try Row.fetchAll(database, sql: sql, arguments: [databaseId.databaseText]).map(DatabaseProperty.init(row:))
    }

    public func property(_ id: UUID) throws -> DatabaseProperty? {
        try Row.fetchOne(database.cachedStatement(sql: "SELECT * FROM db_property WHERE id = ?"), arguments: [id.databaseText])
            .map(DatabaseProperty.init(row:))
    }

    public func options(ofProperty propertyId: UUID, includingDeleted: Bool = false) throws -> [SelectOption] {
        let sql = "SELECT * FROM db_select_option WHERE propertyId = ?" + (includingDeleted ? "" : " AND deletedAt IS NULL")
            + " ORDER BY sortKey, id"
        return try Row.fetchAll(database, sql: sql, arguments: [propertyId.databaseText]).map(SelectOption.init(row:))
    }

    public func option(_ id: UUID) throws -> SelectOption? {
        try Row.fetchOne(database, sql: "SELECT * FROM db_select_option WHERE id = ?", arguments: [id.databaseText])
            .map(SelectOption.init(row:))
    }

    public func views(ofDatabase databaseId: UUID) throws -> [DatabaseView] {
        try Row.fetchAll(database, sql: "SELECT * FROM db_view WHERE databaseId = ? ORDER BY sortKey, id",
                         arguments: [databaseId.databaseText]).map(DatabaseView.init(row:))
    }

    public func view(_ id: UUID) throws -> DatabaseView? {
        try Row.fetchOne(database, sql: "SELECT * FROM db_view WHERE id = ?", arguments: [id.databaseText]).map(DatabaseView.init(row:))
    }

    public func cell(rowId: UUID, propertyId: UUID) throws -> CellRecord? {
        try Row.fetchOne(database.cachedStatement(sql: "SELECT rowId, propertyId, value, hlc FROM db_cell WHERE rowId = ? AND propertyId = ?"),
                         arguments: [rowId.databaseText, propertyId.databaseText]).map(CellRecord.init(row:))
    }

    /// Ячейки строки, в том числе пустые записи с меткой.
    public func cells(ofRow rowId: UUID) throws -> [CellRecord] {
        try Row.fetchAll(database, sql: "SELECT rowId, propertyId, value, hlc FROM db_cell WHERE rowId = ? ORDER BY propertyId",
                         arguments: [rowId.databaseText]).map(CellRecord.init(row:))
    }

    public func relationLink(_ id: UUID) throws -> RelationLink? {
        try Row.fetchOne(database.cachedStatement(sql: "SELECT * FROM db_relation_link WHERE id = ?"), arguments: [id.databaseText])
            .map(RelationLink.init(row:))
    }

    /// Связи строки по свойству, по порядку; снятые — только с `includingRemoved`.
    public func relationLinks(propertyId: UUID, rowId: UUID, includingRemoved: Bool = false) throws -> [RelationLink] {
        let sql = "SELECT * FROM db_relation_link WHERE propertyId = ? AND rowId = ?" + (includingRemoved ? "" : " AND isPresent = 1")
            + " ORDER BY sortKey, id"
        return try Row.fetchAll(database, sql: sql, arguments: [propertyId.databaseText, rowId.databaseText]).map(RelationLink.init(row:))
    }

    /// Связи, которые указывают на строку (ответное свойство пары и сводки читают по ним).
    public func relationLinks(propertyId: UUID, targetRowId: UUID) throws -> [RelationLink] {
        try Row.fetchAll(database, sql: "SELECT * FROM db_relation_link WHERE propertyId = ? AND targetRowId = ? AND isPresent = 1 ORDER BY sortKey, id",
                         arguments: [propertyId.databaseText, targetRowId.databaseText]).map(RelationLink.init(row:))
    }

    public func rowOrder(viewId: UUID, rowId: UUID) throws -> RowOrder? {
        try Row.fetchOne(database, sql: "SELECT * FROM db_row_order WHERE id = ?",
                         arguments: [RowOrder.id(viewId: viewId, rowId: rowId).databaseText]).map(RowOrder.init(row:))
    }

    // MARK: Запись

    /// Записать базу; новую метку получают изменённые поля (у новой — все).
    @discardableResult
    public func saveDatabase(_ schema: DatabaseSchema) throws -> DatabaseSchema {
        guard try page(schema.pageId) != nil else { throw NotesStoreError.pageNotFound(schema.pageId) }
        return try saveRecord(schema, stored: try database(schema.pageId), write: { try $0.save(in: database) }) {
            changes.database.databases.append($0)
        }
    }

    @discardableResult
    public func saveProperty(_ property: DatabaseProperty) throws -> DatabaseProperty {
        guard !property.name.isEmpty else { throw NotesStoreError.invalidRecord("у свойства должно быть название") }
        return try saveRecord(property, stored: try self.property(property.id), write: { try $0.save(in: database) }) {
            changes.database.properties.append($0)
        }
    }

    @discardableResult
    public func saveOption(_ option: SelectOption) throws -> SelectOption {
        try saveRecord(option, stored: try self.option(option.id), write: { try $0.save(in: database) }) {
            changes.database.options.append($0)
        }
    }

    @discardableResult
    public func saveView(_ view: DatabaseView) throws -> DatabaseView {
        try saveRecord(view, stored: try self.view(view.id), write: { try $0.save(in: database) }) {
            changes.database.views.append($0)
        }
    }

    @discardableResult
    public func saveRelationLink(_ link: RelationLink) throws -> RelationLink {
        try saveRecord(link, stored: try relationLink(link.id), write: { try $0.save(in: database) }) {
            changes.database.relationLinks.append($0)
        }
    }

    /// Записать значение ячейки (`nil` — пусто). Правка ячейки — правка строки: её «изменено» сдвигается.
    @discardableResult
    public func setCell(rowId: UUID, propertyId: UUID, value: JSONValue?) throws -> CellRecord {
        let value = value == .null ? nil : value
        if let stored = try cell(rowId: rowId, propertyId: propertyId), stored.value == value { return stored }
        let cell = CellRecord(rowId: rowId, propertyId: propertyId, value: value, hlc: clock.now())
        try cell.save(in: database)
        try touchRow(rowId)
        changes.database.cells.append(cell)
        return cell
    }

    /// Значения одного свойства у многих строк (смена типа): прежние значения вызывающий уже знает и шлёт только
    /// изменённые; «изменено» строк сдвигается одним запросом на пачку.
    public func setCells(_ values: [(rowId: UUID, value: JSONValue?)], propertyId: UUID) throws {
        let now = Date()
        for start in stride(from: 0, to: values.count, by: 500) {
            let chunk = values[start..<min(start + 500, values.count)]
            for (rowId, value) in chunk {
                let cell = CellRecord(rowId: rowId, propertyId: propertyId, value: value == .null ? nil : value, hlc: clock.now())
                try cell.save(in: database)
                changes.database.cells.append(cell)
            }
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try database.execute(sql: "UPDATE page SET updatedAt = ? WHERE id IN (\(marks))",
                                 arguments: StatementArguments([now.databaseValue] + chunk.map { $0.rowId.databaseText.databaseValue }))
        }
    }

    /// Ручное место строки в виде.
    @discardableResult
    public func setRowOrder(viewId: UUID, rowId: UUID, sortKey: FractionalSortKey) throws -> RowOrder {
        let order = RowOrder(viewId: viewId, rowId: rowId, sortKey: sortKey, hlc: clock.now())
        try order.save(in: database)
        changes.database.rowOrders.append(order)
        return order
    }

    // MARK: Правки с других Mac (модуль Sync)

    package func writeReplicatedDatabase(_ schema: DatabaseSchema, changedFields: Set<DatabaseSchema.Field>, isNew: Bool) throws {
        try schema.save(in: database)
        changes.database.databases.append(RecordChange(record: schema, changedFields: changedFields, isNew: isNew))
    }

    package func writeReplicatedProperty(_ property: DatabaseProperty, changedFields: Set<DatabaseProperty.Field>, isNew: Bool) throws {
        try property.save(in: database)
        changes.database.properties.append(RecordChange(record: property, changedFields: changedFields, isNew: isNew))
    }

    package func writeReplicatedOption(_ option: SelectOption, changedFields: Set<SelectOption.Field>, isNew: Bool) throws {
        try option.save(in: database)
        changes.database.options.append(RecordChange(record: option, changedFields: changedFields, isNew: isNew))
    }

    package func writeReplicatedView(_ view: DatabaseView, changedFields: Set<DatabaseView.Field>, isNew: Bool) throws {
        try view.save(in: database)
        changes.database.views.append(RecordChange(record: view, changedFields: changedFields, isNew: isNew))
    }

    package func writeReplicatedRelationLink(_ link: RelationLink, changedFields: Set<RelationLink.Field>, isNew: Bool) throws {
        try link.save(in: database)
        changes.database.relationLinks.append(RecordChange(record: link, changedFields: changedFields, isNew: isNew))
    }

    package func writeReplicatedCell(_ cell: CellRecord) throws {
        try cell.save(in: database)
        try touchRow(cell.rowId)
        changes.database.cells.append(cell)
    }

    package func writeReplicatedRowOrder(_ order: RowOrder) throws {
        try order.save(in: database)
        changes.database.rowOrders.append(order)
    }

    /// Все записи баз этого Mac — для снимка и первой отправки.
    package func allDatabaseRecords() throws -> (databases: [DatabaseSchema], properties: [DatabaseProperty], options: [SelectOption],
                                                 views: [DatabaseView], cells: [CellRecord], links: [RelationLink], rowOrders: [RowOrder]) {
        (try Row.fetchAll(database, sql: "SELECT * FROM db_database ORDER BY pageId").map(DatabaseSchema.init(row:)),
         try Row.fetchAll(database, sql: "SELECT * FROM db_property ORDER BY databaseId, sortKey, id").map(DatabaseProperty.init(row:)),
         try Row.fetchAll(database, sql: "SELECT * FROM db_select_option ORDER BY propertyId, sortKey, id").map(SelectOption.init(row:)),
         try Row.fetchAll(database, sql: "SELECT * FROM db_view ORDER BY databaseId, sortKey, id").map(DatabaseView.init(row:)),
         try Row.fetchAll(database, sql: "SELECT rowId, propertyId, value, hlc FROM db_cell ORDER BY rowId, propertyId").map(CellRecord.init(row:)),
         try Row.fetchAll(database, sql: "SELECT * FROM db_relation_link ORDER BY id").map(RelationLink.init(row:)),
         try Row.fetchAll(database, sql: "SELECT * FROM db_row_order ORDER BY id").map(RowOrder.init(row:)))
    }

    /// База, которой принадлежит свойство или вид (страница-база для `pageId` пачки).
    package func databaseId(ofProperty propertyId: UUID) throws -> UUID? {
        try String.fetchOne(database.cachedStatement(sql: "SELECT databaseId FROM db_property WHERE id = ?"), arguments: [propertyId.databaseText])
            .flatMap(UUID.init(uuidString:))
    }

    package func databaseId(ofView viewId: UUID) throws -> UUID? {
        try String.fetchOne(database, sql: "SELECT databaseId FROM db_view WHERE id = ?", arguments: [viewId.databaseText])
            .flatMap(UUID.init(uuidString:))
    }

    /// Строки `search_index` значений ячеек — с этого номера: ниже — названия страниц (`-rowid`) и блоки (`rowid`).
    public static let cellSearchRowidOffset: Int64 = 1 << 40

    // MARK: Внутреннее

    private func saveRecord<Record: ClockedDatabaseRecord>(_ record: Record, stored: Record?, write: (Record) throws -> Void,
                                                           record changed: (RecordChange<Record>) -> Void) throws -> Record {
        var saved = record
        if let stored {
            let fields = record.changedFields(comparedTo: stored)
            guard !fields.isEmpty else { return stored }
            saved.fieldClocks = stored.fieldClocks
            saved.fieldClocks.stamp(fields, with: clock.now())
            try write(saved)
            changed(RecordChange(record: saved, changedFields: fields, isNew: false))
        } else {
            let fields = Set(Record.Field.allCases)
            saved.fieldClocks.stamp(fields, with: clock.now())
            try write(saved)
            changed(RecordChange(record: saved, changedFields: fields, isNew: true))
        }
        return saved
    }

    private func touchRow(_ rowId: UUID) throws {
        try database.execute(sql: "UPDATE page SET updatedAt = ? WHERE id = ?", arguments: [Date(), rowId.databaseText])
    }

    /// Стереть записи баз вместе со страницей: её ячейки, связи и места в видах; у страницы-базы — схему,
    /// свойства, варианты, виды и вычисленное.
    func eraseDatabaseRecords(ofPage pageId: UUID) throws {
        let id = pageId.databaseText
        changes.database.erasedLinks += try Row.fetchAll(database, sql: """
            SELECT * FROM db_relation_link WHERE (rowId = ?1 OR targetRowId = ?1) AND isPresent = 1
            """, arguments: [id]).map(RelationLink.init(row:))
        for sql in [
            "DELETE FROM db_cell WHERE rowId = ?",
            "DELETE FROM db_computed WHERE rowId = ?",
            "DELETE FROM db_relation_link WHERE rowId = ?1 OR targetRowId = ?1",
            "DELETE FROM search_index WHERE rowid IN (SELECT searchRowid + \(Self.cellSearchRowidOffset) FROM db_cell_search WHERE rowId = ?)",
            "DELETE FROM db_cell_search WHERE rowId = ?",
            "DELETE FROM db_row_order WHERE rowId = ?",
            "DELETE FROM db_row_order WHERE viewId IN (SELECT id FROM db_view WHERE databaseId = ?)",
            "DELETE FROM db_select_option WHERE propertyId IN (SELECT id FROM db_property WHERE databaseId = ?)",
            "DELETE FROM db_computed WHERE propertyId IN (SELECT id FROM db_property WHERE databaseId = ?)",
            "DELETE FROM db_property WHERE databaseId = ?",
            "DELETE FROM db_view WHERE databaseId = ?",
            "DELETE FROM db_database WHERE pageId = ?",
        ] {
            try database.cachedStatement(sql: sql).execute(arguments: [id])
        }
    }
}
