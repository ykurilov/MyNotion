import Foundation
import GRDB
import NotesCore

/// Смена типа на большой базе — в фоне, по образцу пересчёта формул (research R21, SC-305): снимок свойства читается
/// и значения переводятся вне записи; первая короткая запись — тип, настройки и варианты, дальше значения пачками по
/// `batchSize` строк, между пачками очередь записи свободна — правки с главного потока проходят. Пачка пишет значение,
/// только если в ячейке всё ещё прочитанное (иначе её уже поправили). ⌘Z — один шаг, тоже в фоне.
extension DatabaseOperations {
    /// С этого числа строк меню и панель меняют тип в фоне; меньше — одной записью сразу.
    public static let backgroundRewriteThreshold = 1_000

    /// Сменить тип в фоне. Следующая фоновая перезапись ждёт предыдущую. `beforeWriting` — для проверок: между
    /// чтением и записью.
    @discardableResult
    public func startChangeType(_ propertyId: UUID, to kind: PropertyKind, config: JSONValue = .emptyObject,
                                beforeWriting: (@Sendable () throws -> Void)? = nil) -> Task<Void, any Error> {
        enqueueRewrite(actionName: "Смена типа") { operations in
            let store = operations.store
            let old = try store.write { try Self.requireProperty(propertyId, $0) }
            guard old.kind != .title, kind != .title else { throw NotesStoreError.invalidRecord("у «Названия» тип не меняется") }
            guard old.kind != kind else { return nil }
            if kind == .uniqueId { try store.write { try UniqueIds.ensureNone(inDatabase: old.databaseId, except: propertyId, in: $0) } }
            let plan = try await Task.detached(priority: .userInitiated) { try PropertyRewrite.planTypeChange(old, to: kind, config: config, store: store) }.value
            try beforeWriting?()
            return plan
        }
    }

    /// Вернуть свойство к снимку в фоне (шаг отмены и повтора большой смены типа); свой шаг отмены не ставит — его
    /// ставит `registerRewriteUndo` в самой отмене, иначе ⇧⌘Z не нашёл бы шага.
    @discardableResult
    func startRestore(_ state: PropertyState, actionName: String) -> Task<Void, any Error> {
        enqueueRewrite(actionName: nil) { operations in
            let store = operations.store
            return try await Task.detached(priority: .userInitiated) { try PropertyRewrite.planRestore(state, store: store) }.value
        }
    }

    /// Очередь фоновых перезаписей: план (на чтении), запись пачками, шаг отмены — по готовности.
    private func enqueueRewrite(actionName: String?,
                                plan makePlan: @escaping @MainActor (DatabaseOperations) async throws -> PropertyRewrite.Plan?) -> Task<Void, any Error> {
        let previous = pendingRewrite
        let task = Task { @MainActor [weak self] in
            _ = try? await previous?.value
            guard let self, let plan = try await makePlan(self) else { return }
            let store = self.store
            let databaseId = plan.target.databaseId
            let after = try await Task.detached(priority: .userInitiated) { () throws -> PropertyState in
                try PropertyRewrite.write(plan, store: store)
                return try store.database.dbWriter.read { try PropertyState.read(plan.target.id, in: $0) }
            }.value
            if let actionName { self.registerRewriteUndo(actionName, undoTo: plan.before, redoTo: after) }
            Self.announce([databaseId])
        }
        pendingRewrite = task
        return task
    }
}

extension DatabaseOperations {
    /// Шаг отмены фоновой перезаписи: вернуть к `undoTo`; в самой отмене ставится шаг повтора — к `redoTo`.
    func registerRewriteUndo(_ actionName: String, undoTo: PropertyState, redoTo: PropertyState) {
        guard let undoManager else { return }
        // Готовность приходит позже события: без группировки по событиям шаг ставится в свою группу.
        let ownGroup = !undoManager.groupsByEvent && undoManager.groupingLevel == 0
        if ownGroup { undoManager.beginUndoGrouping() }
        registerUndo(actionName) { operations in
            operations.startRestore(undoTo, actionName: actionName)
            operations.registerRewriteUndo(actionName, undoTo: redoTo, redoTo: undoTo)
        }
        if ownGroup { undoManager.endUndoGrouping() }
    }
}

/// Фоновая перезапись значений одного свойства: что записать (план на чтении) и как (пачками со сверкой).
enum PropertyRewrite {
    static let batchSize = 200

    struct Plan: Sendable {
        /// Свойство, каким оно было при чтении: шаг отмены возвращает его.
        var before: PropertyState
        /// Запись свойства после перезаписи (тип, настройки).
        var target: DatabaseProperty
        /// Варианты, которые записываются как есть (оставленные, удалённые, возвращённые).
        var options: [SelectOption]
        /// Новые варианты по порядку (смена типа на выбор): создаются первой записью.
        var newOptionNames: [String]
        /// Значение строки: готовое или названия вариантов; `expected` — что было в ячейке при чтении.
        var values: [(rowId: UUID, result: TypeChange.Result, expected: JSONValue?)]
        /// Новое свойство ID: строкам без номера — номера.
        var numbersRows: Bool
    }

    /// Смена типа: снимок, перевод каждого значения (contracts/property-types.md, «Смена типа»).
    static func planTypeChange(_ old: DatabaseProperty, to kind: PropertyKind, config: JSONValue, store: NotesStore) throws -> Plan {
        try store.database.dbWriter.read { db in
            let before = try PropertyState.read(old.id, in: db)
            let catalog = try DatabaseCatalog.read(old.databaseId, in: db)
            let source = catalog.context(for: old)
            var target = before.property
            target.kind = kind
            target.config = config
            let keepsOptions = TypeChange.optionKinds.contains(old.kind) && TypeChange.optionKinds.contains(kind)
            let now = Date()
            let options = before.options.filter { $0.deletedAt == nil }.compactMap { option -> SelectOption? in
                var option = option
                if keepsOptions {
                    guard kind == .status, option.statusGroup == nil else { return nil }
                    option.statusGroup = .todo
                } else {
                    option.deletedAt = now
                }
                return option
            }
            let targetContext = PropertyContext(property: target, options: keepsOptions ? before.options.filter { $0.deletedAt == nil } : [])
            let rowIds = try String.fetchAll(db, sql: "SELECT id FROM page WHERE parentId = ? ORDER BY sortKey, id",
                                             arguments: [old.databaseId.databaseText]).compactMap(UUID.init(uuidString:))
            var sources: [(UUID, JSONValue?)] = []
            if old.kind.storesCells {
                sources = rowIds.compactMap { rowId in before.cells[rowId].map { (rowId, $0) } }
            } else {
                for start in stride(from: 0, to: rowIds.count, by: 500) {
                    let chunk = Array(rowIds[start..<min(start + 500, rowIds.count)])
                    let snapshots = try RowWindowReader.read(chunk, catalog: catalog, in: db)
                    sources += chunk.map { rowId in (rowId, snapshots[rowId].flatMap { DatabaseOperations.sourceValue(of: old, in: $0, context: source) }) }
                }
            }
            var values: [(rowId: UUID, result: TypeChange.Result, expected: JSONValue?)] = []
            var newNames: [String] = []
            var known = Set(targetContext.options.map { SortableText.make($0.name) })
            for (rowId, value) in sources {
                let expected = before.cells[rowId] ?? nil
                var result = TypeChange.convert(value, from: source, to: targetContext)
                if !kind.storesCells { result = .value(nil) }
                if case .optionNames(let names) = result {
                    for name in names where known.insert(SortableText.make(name)).inserted { newNames.append(name) }
                }
                if case .value(let converted) = result, converted == expected { continue }
                values.append((rowId, result, expected))
            }
            return Plan(before: before, target: target, options: options, newOptionNames: newNames, values: values,
                        numbersRows: kind == .uniqueId)
        }
    }

    /// Вернуть к снимку: тип, настройки, варианты, значения; снимок «как сейчас» — шаг повтора.
    static func planRestore(_ state: PropertyState, store: NotesStore) throws -> Plan {
        try store.database.dbWriter.read { db in
            let current = try PropertyState.read(state.property.id, in: db)
            let own = Set(state.options.map(\.id))
            let now = Date()
            var options = state.options
            for var option in current.options where !own.contains(option.id) && option.deletedAt == nil {
                option.deletedAt = now
                options.append(option)
            }
            var values: [(rowId: UUID, result: TypeChange.Result, expected: JSONValue?)] = []
            for rowId in Set(state.cells.keys).union(current.cells.keys) {
                let wanted = state.cells[rowId] ?? nil
                let now = current.cells[rowId] ?? nil
                if wanted != now { values.append((rowId, .value(wanted), now)) }
            }
            return Plan(before: current, target: state.property, options: options, newOptionNames: [], values: values, numbersRows: false)
        }
    }

    /// Записать план: свойство и варианты — одной короткой записью, значения — пачками со сверкой.
    static func write(_ plan: Plan, store: NotesStore) throws {
        let property = plan.target
        var optionIds: [String: String] = [:]
        try store.write { transaction throws in
            try transaction.saveProperty(property)
            for option in plan.options { try transaction.saveOption(option) }
            let existing = try transaction.options(ofProperty: property.id)
            for option in existing { optionIds[SortableText.make(option.name)] = option.id.databaseText }
            var last = existing.map(\.sortKey).max()
            for (index, name) in plan.newOptionNames.enumerated() {
                let option = try transaction.saveOption(SelectOption(propertyId: property.id, name: name,
                                                                     color: OptionPalette.colors[(existing.count + index) % OptionPalette.colors.count],
                                                                     sortKey: .between(last, nil), statusGroup: property.kind == .status ? .todo : nil))
                last = option.sortKey
                optionIds[SortableText.make(name)] = option.id.databaseText
            }
        }
        let resolved: [(rowId: UUID, value: JSONValue?, expected: JSONValue?)] = plan.values.map { item in
            switch item.result {
            case .value(let value): return (item.rowId, value, item.expected)
            case .optionNames(let names):
                let ids = names.compactMap { optionIds[SortableText.make($0)] }.map(JSONValue.string)
                return (item.rowId, property.kind == .multiSelect ? .array(ids) : ids.first, item.expected)
            }
        }
        for start in stride(from: 0, to: resolved.count, by: batchSize) {
            let batch = resolved[start..<min(start + batchSize, resolved.count)]
            try store.write { transaction throws in
                let current = try currentValues(of: property.id, rows: batch.map(\.rowId), in: transaction.database)
                // Ячейку поправили после чтения — правка главнее.
                let writes = batch.filter { (current[$0.rowId] ?? nil) == $0.expected }.map { (rowId: $0.rowId, value: $0.value) }
                try transaction.setCells(writes, propertyId: property.id)
            }
        }
        if plan.numbersRows {
            try store.write { try UniqueIds.numberRows(of: property.id, inDatabase: property.databaseId, in: $0) }
        }
    }

    static func currentValues(of propertyId: UUID, rows: [UUID], in db: Database) throws -> [UUID: JSONValue?] {
        let marks = Array(repeating: "?", count: rows.count).joined(separator: ",")
        var result: [UUID: JSONValue?] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT rowId, value FROM db_cell WHERE propertyId = ? AND rowId IN (\(marks))",
                                    arguments: StatementArguments([propertyId.databaseText] + rows.map(\.databaseText))) {
            guard let rowId = UUID(uuidString: row[0]) else { continue }
            let text: String? = row[1]
            result[rowId] = text.flatMap(JSONValue.init(jsonText:))
        }
        return result
    }
}

extension PropertyState {
    /// Снимок на чтении (без транзакции записи): запись свойства, все варианты, все значения.
    static func read(_ propertyId: UUID, in db: Database) throws -> PropertyState {
        guard let property = try Row.fetchOne(db, sql: "SELECT * FROM db_property WHERE id = ?", arguments: [propertyId.databaseText])
            .map(DatabaseProperty.init(row:)) else { throw NotesStoreError.invalidRecord("свойства нет") }
        let options = try Row.fetchAll(db, sql: "SELECT * FROM db_select_option WHERE propertyId = ?", arguments: [propertyId.databaseText])
            .map(SelectOption.init(row:))
        let cells = try DatabaseRewriteCells.read(propertyId, in: db)
        return PropertyState(property: property, options: options, cells: cells)
    }
}

/// Значения свойства по строкам на чтении.
enum DatabaseRewriteCells {
    static func read(_ propertyId: UUID, in db: Database) throws -> [UUID: JSONValue?] {
        var cells: [UUID: JSONValue?] = [:]
        let cursor = try Row.fetchCursor(db, sql: "SELECT rowId, value FROM db_cell WHERE propertyId = ?", arguments: [propertyId.databaseText])
        while let row = try cursor.next() {
            guard let rowId = UUID(uuidString: row[0]) else { continue }
            let text: String? = row[1]
            cells[rowId] = text.flatMap { FastJSON.parse($0) }
        }
        return cells
    }
}

/// Цвета новых вариантов по кругу (как у смены типа одной записью).
enum OptionPalette {
    static let colors: [OptionColor] = [.gray, .brown, .orange, .yellow, .green, .blue, .purple, .pink, .red, .default]
}
