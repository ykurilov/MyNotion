import Foundation
import GRDB
import NotesCore

/// Сторона вставки нового свойства от колонки (меню колонки «Вставить слева / справа»).
public enum ColumnSide: Sendable, Hashable {
    case left, right
}

/// Свойства и колонки вида (US1, FR-305, research R11): переименовать, переставить, ширина, вставить рядом, дублировать
/// со значениями, удалить навсегда, сменить тип. Каждая правка — один шаг ⌘Z.
extension DatabaseOperations {
    /// Имя нового свойства у «Вставить слева / справа» (Notion 7.39 — «Property», затем «Property 1»…).
    nonisolated static let newPropertyName = "Свойство"
    /// Метка в `config` у свойства, удалённого навсегда: запись остаётся следом для синхронизации, как снятая связь.
    nonisolated static let erasedKey = "erased"

    // MARK: Имя и порядок

    /// Переименовать свойство; пустое имя не принимается (data-model.md, `name`).
    public func renameProperty(_ propertyId: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NotesStoreError.invalidRecord("имя свойства пустое") }
        try perform("Переименование свойства") { transaction in
            var property = try Self.requireProperty(propertyId, transaction)
            let previous = property.name
            property.name = trimmed
            try transaction.saveProperty(property)
            return ((), { try $0.renameProperty(propertyId, to: previous) })
        }
    }

    /// Место свойства в базе (окно «Свойства», страница строки): `index` — среди неудалённых свойств.
    public func moveProperty(_ propertyId: UUID, to index: Int) throws {
        try perform("Перестановка свойства") { transaction in
            var property = try Self.requireProperty(propertyId, transaction)
            let others = try transaction.properties(ofDatabase: property.databaseId).filter { $0.id != propertyId }
            let position = min(max(index, 0), others.count)
            let previousIndex = try transaction.properties(ofDatabase: property.databaseId).firstIndex { $0.id == propertyId } ?? 0
            property.sortKey = Self.key(between: position > 0 ? others[position - 1].sortKey : nil,
                                        position < others.count ? others[position].sortKey : nil)
            try transaction.saveProperty(property)
            return ((), { try $0.moveProperty(propertyId, to: previousIndex) })
        }
    }

    /// Переставить колонку в виде (`index` — среди видимых колонок). «Название» всегда первое: само не двигается,
    /// перед ним колонку не поставить. Порядок свойств базы не меняется — у каждого вида свой порядок колонок.
    public func moveColumn(_ propertyId: UUID, in viewId: UUID, to index: Int) throws {
        try editColumns(of: viewId, actionName: "Перестановка колонки") { entries, catalog in
            guard propertyId != catalog.titleProperty?.id, let from = entries.firstIndex(where: { DatabaseColumns.id(of: $0) == propertyId })
            else { return }
            let entry = entries.remove(at: from)
            let visible = entries.indices.filter { Self.isShown(entries[$0], catalog: catalog) }
            let target = min(max(index, 1), visible.count)
            entries.insert(entry, at: target < visible.count ? visible[target] : (visible.last.map { $0 + 1 } ?? entries.count))
        }
    }

    /// Ширина колонки в виде (протяжка края — один шаг по отпусканию); не уже `DatabaseColumns.minimumWidth`.
    public func setColumnWidth(_ propertyId: UUID, in viewId: UUID, to width: Double) throws {
        try editColumns(of: viewId, actionName: "Ширина колонки") { entries, _ in
            guard let index = entries.firstIndex(where: { DatabaseColumns.id(of: $0) == propertyId }) else { return }
            entries[index] = DatabaseColumns.setting("width", to: .number(max(width.rounded(), DatabaseColumns.minimumWidth)), in: entries[index])
        }
    }

    // MARK: Новое свойство рядом и копия

    /// «Вставить слева / справа»: текстовое свойство «Свойство» («Свойство 1»…) рядом с колонкой в виде и в базе.
    /// Слева от «Названия» нельзя — встаёт справа. ⌘Z — в «Удалённые свойства».
    @discardableResult
    public func insertProperty(beside anchorId: UUID, side: ColumnSide, in viewId: UUID, kind: PropertyKind = .text) throws -> DatabaseProperty {
        try perform("Новое свойство") { transaction in
            let anchor = try Self.requireProperty(anchorId, transaction)
            if kind == .uniqueId { try UniqueIds.ensureNone(inDatabase: anchor.databaseId, in: transaction) }
            let side = anchor.kind == .title ? .right : side
            let siblings = try transaction.properties(ofDatabase: anchor.databaseId, includingDeleted: true)
            let name = Self.freeName(Self.newPropertyName, taken: Set(siblings.filter { $0.deletedAt == nil }.map(\.name)))
            let property = try transaction.saveProperty(DatabaseProperty(databaseId: anchor.databaseId, name: name, kind: kind,
                                                                         sortKey: Self.key(beside: anchor, side: side, among: siblings)))
            try Self.placeColumn(property.id, beside: anchorId, side: side, in: viewId, transaction)
            if kind == .uniqueId { try UniqueIds.numberRows(of: property.id, inDatabase: anchor.databaseId, in: transaction) }
            return (property, { try $0.setDeleted(property.id, true) })
        }
    }

    /// «Дублировать свойство»: копия «Имя (1)» справа от оригинала (в базе и в виде) со значениями и вариантами.
    /// Связи строк у связи и номера ID не копируются: связь копирует US4, второго ID в базе не бывает.
    @discardableResult
    public func duplicateProperty(_ propertyId: UUID, in viewId: UUID?) throws -> DatabaseProperty {
        try perform("Дублирование свойства") { transaction in
            let original = try Self.requireProperty(propertyId, transaction)
            guard original.kind != .title, original.kind != .uniqueId else { throw NotesStoreError.invalidRecord("это свойство не дублируется") }
            let siblings = try transaction.properties(ofDatabase: original.databaseId, includingDeleted: true)
            let taken = Set(siblings.filter { $0.deletedAt == nil }.map(\.name))
            var number = 1
            while taken.contains("\(original.name) (\(number))") { number += 1 }
            let copy = try transaction.saveProperty(DatabaseProperty(databaseId: original.databaseId, name: "\(original.name) (\(number))",
                                                                     kind: original.kind, config: original.config,
                                                                     sortKey: Self.key(beside: original, side: .right, among: siblings)))
            var optionIds: [String: JSONValue] = [:]
            for option in try transaction.options(ofProperty: original.id) {
                let saved = try transaction.saveOption(SelectOption(propertyId: copy.id, name: option.name, color: option.optionColor,
                                                                    sortKey: option.sortKey, statusGroup: option.statusGroup))
                optionIds[option.id.databaseText] = .string(saved.id.databaseText)
            }
            func remap(_ value: JSONValue) -> JSONValue {
                switch value {
                case .string(let id): optionIds[id] ?? value
                case .array(let ids): .array(ids.map(remap))
                default: value
                }
            }
            let isOption = [.select, .multiSelect, .status].contains(original.kind)
            for (rowId, value) in try Self.cellValues(of: original.id, transaction) {
                guard let value else { continue }
                try transaction.setCell(rowId: rowId, propertyId: copy.id, value: isOption ? remap(value) : value)
            }
            if let viewId { try Self.placeColumn(copy.id, beside: original.id, side: .right, in: viewId, transaction) }
            return (copy, { try $0.setDeleted(copy.id, true) })
        }
    }

    // MARK: Удалить навсегда и сменить тип

    /// «Удалить навсегда» из «Удалённых свойств»: значения и варианты стираются, свойство больше не возвращается.
    /// Запись свойства остаётся следом с меткой `erased` — иначе другой Mac вернул бы его. ⌘Z возвращает всё.
    public func eraseProperty(_ propertyId: UUID) throws {
        try perform("Удаление свойства навсегда") { transaction in
            var property = try Self.requireProperty(propertyId, transaction)
            guard property.deletedAt != nil, property.kind != .title else {
                throw NotesStoreError.invalidRecord("навсегда удаляется только свойство из «Удалённых свойств»")
            }
            let before = try PropertyState.capture(propertyId, transaction)
            for (rowId, value) in before.cells where value != nil { try transaction.setCell(rowId: rowId, propertyId: propertyId, value: nil) }
            for var option in before.options where option.deletedAt == nil {
                option.deletedAt = Date()
                try transaction.saveOption(option)
            }
            property.config[Self.erasedKey] = true
            try transaction.saveProperty(property)
            return ((), { try $0.restoreProperty(before, actionName: "Удаление свойства навсегда") })
        }
    }

    /// Сменить тип (contracts/property-types.md, «Смена типа», FR-318): значения всех строк переводятся, варианты по
    /// названиям находятся или создаются (цвета по кругу). ⌘Z возвращает тип, настройки, варианты и все значения
    /// одним шагом. У «Названия» тип не меняется; второе ID в базе не заводится.
    public func changeType(_ propertyId: UUID, to kind: PropertyKind, config: JSONValue = .emptyObject) throws {
        try performChange("Смена типа") { transaction in
            let old = try Self.requireProperty(propertyId, transaction)
            guard old.kind != .title, kind != .title else { throw NotesStoreError.invalidRecord("у «Названия» тип не меняется") }
            guard old.kind != kind else { return nil }
            if kind == .uniqueId { try UniqueIds.ensureNone(inDatabase: old.databaseId, except: propertyId, in: transaction) }
            let before = try PropertyState.capture(propertyId, transaction)
            let catalog = try DatabaseCatalog.read(old.databaseId, in: transaction.database)
            let source = catalog.context(for: old)
            var changed = old
            changed.kind = kind
            changed.config = config
            // Выбор, множественный выбор и статус — варианты те же; у остальных типов варианты теряют смысл.
            let keepsOptions = TypeChange.optionKinds.contains(old.kind) && TypeChange.optionKinds.contains(kind)
            for var option in before.options where option.deletedAt == nil {
                if keepsOptions {
                    guard kind == .status, option.statusGroup == nil else { continue }
                    option.statusGroup = .todo
                } else {
                    option.deletedAt = Date()
                }
                try transaction.saveOption(option)
            }
            var options = OptionMaker(property: changed, transaction: transaction,
                                      existing: keepsOptions ? try transaction.options(ofProperty: propertyId) : [])
            let rowIds = try String.fetchAll(transaction.database, sql: "SELECT id FROM page WHERE parentId = ? ORDER BY sortKey, id",
                                             arguments: [old.databaseId.databaseText]).compactMap(UUID.init(uuidString:))
            for start in stride(from: 0, to: rowIds.count, by: 500) {
                let chunk = Array(rowIds[start..<min(start + 500, rowIds.count)])
                let snapshots = try RowWindowReader.read(chunk, catalog: catalog, in: transaction.database)
                for rowId in chunk {
                    let value = snapshots[rowId].flatMap { Self.sourceValue(of: old, in: $0, context: source) }
                    let converted: JSONValue?
                    switch TypeChange.convert(value, from: source, to: options.context) {
                    case .value(let result): converted = result
                    case .optionNames(let names):
                        let ids = try names.map { JSONValue.string(try options.option(named: $0).databaseText) }
                        converted = kind == .multiSelect ? .array(ids) : ids.first
                    }
                    let stored = before.cells[rowId] ?? nil
                    if kind.storesCells || stored != nil { try transaction.setCell(rowId: rowId, propertyId: propertyId, value: kind.storesCells ? converted : nil) }
                }
            }
            try transaction.saveProperty(changed)
            if kind == .uniqueId { try UniqueIds.numberRows(of: propertyId, inDatabase: old.databaseId, in: transaction) }
            return { try $0.restoreProperty(before, actionName: "Смена типа") }
        }
    }

    /// Вернуть свойство, его варианты и значения к снимку; шаг повтора — снимок, каким он был до возврата.
    func restoreProperty(_ state: PropertyState, actionName: String) throws {
        try perform(actionName) { transaction in
            let current = try PropertyState.capture(state.property.id, transaction)
            try state.apply(over: current, transaction)
            return ((), { try $0.restoreProperty(current, actionName: actionName) })
        }
    }

    // MARK: Внутреннее

    /// Правка, которая может ничего не изменить: без изменений (`nil` вместо обратной операции) шага отмены нет.
    func performChange(_ actionName: String, _ body: (NotesTransaction) throws -> (@MainActor (DatabaseOperations) throws -> Void)?) throws {
        var touched: Set<UUID> = []
        let inverse = try store.write { transaction in
            let inverse = try body(transaction)
            touched = Self.touchedPages(transaction.changes)
            return inverse
        }
        guard let inverse else { return }
        registerUndo(actionName, inverse)
        onChange?(touched)
    }

    nonisolated static func requireProperty(_ id: UUID, _ transaction: NotesTransaction) throws -> DatabaseProperty {
        guard let property = try transaction.property(id) else { throw NotesStoreError.invalidRecord("свойства нет") }
        return property
    }

    /// Значение строки в прежнем типе, как его видит смена типа: у названия, дат строки, связи, формулы и сводки — не ячейка.
    nonisolated static func sourceValue(of property: DatabaseProperty, in row: RowSnapshot, context: PropertyContext) -> JSONValue? {
        switch property.kind {
        case .createdTime: PropertyValue.pageDate(row.createdAt, in: context)
        case .lastEditedTime: PropertyValue.pageDate(row.updatedAt, in: context)
        case .formula, .rollup: row.computed[property.id]
        case .relation:
            row.relations[property.id].map { .array($0.map { ["id": .string($0.id.databaseText), "title": .string($0.title)] }) }
        default: row.cells[property.id]
        }
    }

    nonisolated static func cellValues(of propertyId: UUID, _ transaction: NotesTransaction) throws -> [(UUID, JSONValue?)] {
        try Row.fetchAll(transaction.database, sql: "SELECT rowId, value FROM db_cell WHERE propertyId = ?", arguments: [propertyId.databaseText])
            .compactMap { row in
                guard let rowId = UUID(uuidString: row[0]) else { return nil }
                let text: String? = row[1]
                return (rowId, text.flatMap(JSONValue.init(jsonText:)))
            }
    }

    nonisolated static func freeName(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var number = 1
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    /// Ключ между соседями; если соседи сошлись (одинаковые ключи с двух Mac), — сразу после левого.
    nonisolated static func key(between before: FractionalSortKey?, _ after: FractionalSortKey?) -> FractionalSortKey {
        if let before, let after, !(before < after) { return .between(before, nil) }
        return .between(before, after)
    }

    nonisolated static func key(beside anchor: DatabaseProperty, side: ColumnSide, among siblings: [DatabaseProperty]) -> FractionalSortKey {
        let keys = siblings.map(\.sortKey).sorted()
        switch side {
        case .left: return key(between: keys.last { $0 < anchor.sortKey }, anchor.sortKey)
        case .right: return key(between: anchor.sortKey, keys.first { $0 > anchor.sortKey })
        }
    }

    nonisolated static func isShown(_ entry: JSONValue, catalog: DatabaseCatalog) -> Bool {
        guard let id = DatabaseColumns.id(of: entry), catalog.propertiesById[id] != nil else { return false }
        return entry["isVisible"]?.bool != false
    }

    /// Колонка свойства рядом с колонкой `anchorId` вида.
    nonisolated static func placeColumn(_ propertyId: UUID, beside anchorId: UUID, side: ColumnSide, in viewId: UUID, _ transaction: NotesTransaction) throws {
        guard var view = try transaction.view(viewId) else { return }
        let catalog = try DatabaseCatalog.read(view.databaseId, in: transaction.database)
        var entries = DatabaseColumns.normalized(view, catalog: catalog).filter { DatabaseColumns.id(of: $0) != propertyId }
        let entry: JSONValue = ["propertyId": .string(propertyId.databaseText), "isVisible": true]
        if let anchor = entries.firstIndex(where: { DatabaseColumns.id(of: $0) == anchorId }) {
            entries.insert(entry, at: side == .left ? anchor : anchor + 1)
        } else {
            entries.append(entry)
        }
        view.columns = .array(entries)
        try transaction.saveView(view)
    }

    /// Правка колонок вида одним шагом: прежний список колонок возвращает ⌘Z.
    func editColumns(of viewId: UUID, actionName: String, _ edit: (inout [JSONValue], DatabaseCatalog) -> Void) throws {
        try performChange(actionName) { transaction in
            guard var view = try transaction.view(viewId) else { throw NotesStoreError.invalidRecord("вида нет") }
            let previous = view.columns
            let catalog = try DatabaseCatalog.read(view.databaseId, in: transaction.database)
            var entries = DatabaseColumns.normalized(view, catalog: catalog)
            edit(&entries, catalog)
            view.columns = .array(entries)
            let saved = try transaction.saveView(view)
            guard saved.columns != previous else { return nil }
            return { try $0.setColumns(previous, of: viewId, actionName: actionName) }
        }
    }

    func setColumns(_ columns: JSONValue, of viewId: UUID, actionName: String) throws {
        try perform(actionName) { transaction in
            guard var view = try transaction.view(viewId) else { throw NotesStoreError.invalidRecord("вида нет") }
            let previous = view.columns
            view.columns = columns
            try transaction.saveView(view)
            return ((), { try $0.setColumns(previous, of: viewId, actionName: actionName) })
        }
    }
}

/// Свойство целиком — запись, варианты (и удалённые) и все значения: шаг отмены смены типа и удаления навсегда.
struct PropertyState: Sendable {
    var property: DatabaseProperty
    var options: [SelectOption]
    var cells: [UUID: JSONValue?]

    nonisolated static func capture(_ propertyId: UUID, _ transaction: NotesTransaction) throws -> PropertyState {
        let property = try DatabaseOperations.requireProperty(propertyId, transaction)
        return PropertyState(property: property, options: try transaction.options(ofProperty: propertyId, includingDeleted: true),
                             cells: Dictionary(try DatabaseOperations.cellValues(of: propertyId, transaction), uniquingKeysWith: { first, _ in first }))
    }

    /// Записать этот снимок поверх текущего: только то, что отличается.
    func apply(over current: PropertyState, _ transaction: NotesTransaction) throws {
        try transaction.saveProperty(property)
        let own = Set(options.map(\.id))
        for option in options { try transaction.saveOption(option) }
        for var option in current.options where !own.contains(option.id) && option.deletedAt == nil {
            option.deletedAt = Date()
            try transaction.saveOption(option)
        }
        for (rowId, value) in cells where (current.cells[rowId] ?? nil) != value {
            try transaction.setCell(rowId: rowId, propertyId: property.id, value: value)
        }
        for (rowId, value) in current.cells where value != nil && cells[rowId] == nil {
            try transaction.setCell(rowId: rowId, propertyId: property.id, value: nil)
        }
    }
}

/// Варианты при смене типа: по названию — существующий или новый (цвета по кругу), контекст типа растёт вместе с ними.
private struct OptionMaker {
    var property: DatabaseProperty
    let transaction: NotesTransaction
    private(set) var made: [SelectOption] = []
    private var byName: [String: UUID] = [:]
    nonisolated static let palette: [OptionColor] = [.gray, .brown, .orange, .yellow, .green, .blue, .purple, .pink, .red, .default]

    init(property: DatabaseProperty, transaction: NotesTransaction, existing: [SelectOption]) {
        self.property = property
        self.transaction = transaction
        made = existing
        for option in existing { byName[SortableText.make(option.name)] = option.id }
    }

    var context: PropertyContext { PropertyContext(property: property, options: made) }

    mutating func option(named name: String) throws -> UUID {
        let key = SortableText.make(name)
        if let id = byName[key] { return id }
        let color = Self.palette[made.count % Self.palette.count]
        let option = try transaction.saveOption(SelectOption(propertyId: property.id, name: name, color: color,
                                                             sortKey: .between(made.last?.sortKey, nil),
                                                             statusGroup: property.kind == .status ? .todo : nil))
        made.append(option)
        byName[key] = option.id
        return option.id
    }
}

extension DatabaseCatalog {
    /// «Удалённые свойства» окна «Свойства» базы (сверх Notion, spec, Edge Cases): удалённые, но не стёртые навсегда.
    public static func deletedProperties(of databaseId: UUID, in store: NotesStore) throws -> [DatabaseProperty] {
        try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM db_property WHERE databaseId = ? AND deletedAt IS NOT NULL ORDER BY deletedAt DESC, id",
                             arguments: [databaseId.databaseText]).map(DatabaseProperty.init(row:))
                .filter { $0.config[DatabaseOperations.erasedKey] == nil }
        }
    }
}
