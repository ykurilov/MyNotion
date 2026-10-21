import Foundation
import GRDB
import NotesCore

/// Итог запроса вида: id строк по порядку и ключ группы каждой строки (если вид сгруппирован).
public struct ViewQueryResult: Sendable, Hashable {
    public var rowIds: [UUID]
    /// Сравнимое значение свойства группы у каждой строки; `nil` — «Нет …».
    public var groupKeys: [Double?]?

    /// Группы подряд идущих строк с одним ключом (ключ группы — первым в порядке запроса).
    public var groups: [(key: Double?, rows: Range<Int>)] {
        guard let keys = groupKeys, !keys.isEmpty else { return [] }
        var result: [(key: Double?, rows: Range<Int>)] = []
        var start = 0
        for index in 1...keys.count where index == keys.count || keys[index] != keys[start] {
            result.append((keys[start], start..<index))
            start = index
        }
        return result
    }
}

/// Фильтр, поиск и сортировки вида — один запрос SQL по сравнимым колонкам с индексами (research R3): строки базы
/// вне корзины и не шаблоны; условия — подзапросы `IN` по `(propertyId, sortNumber|sortText)`; сортировки — `ORDER BY`
/// по тем же колонкам `db_cell` и `db_computed`; затем место строки в виде (`db_row_order`, иначе `Page.sortKey`).
/// Ячейки не читаются: их читает окно видимых строк.
public struct ViewQuerySQL {
    public let spec: ViewQuerySpec
    public let catalog: DatabaseCatalog
    public var now: Date
    public var calendar: Calendar

    private var joins: [String] = []
    private var joinArguments: [DatabaseValueConvertible?] = []
    private var whereArguments: [DatabaseValueConvertible?] = []

    public init(spec: ViewQuerySpec, catalog: DatabaseCatalog, now: Date = Date(), calendar: Calendar = .current) {
        self.spec = spec
        self.catalog = catalog
        self.now = now
        self.calendar = calendar
    }

    /// Текст запроса и аргументы.
    public mutating func build() -> (sql: String, arguments: StatementArguments) {
        joins = []
        joinArguments = []
        whereArguments = []
        var conditions = ["p.parentId = ?", "p.trashedAt IS NULL", "p.isTemplate = 0"]
        whereArguments.append(spec.databaseId.databaseText)
        if let filter = spec.filter, let predicate = predicate(filter) { conditions.append(predicate) }
        if let search = spec.search?.trimmingCharacters(in: .whitespaces), !search.isEmpty { conditions.append(searchPredicate(search)) }

        var order: [String] = []
        var groupColumn = "NULL"
        if let groupId = spec.groupPropertyId, let property = catalog.propertiesById[groupId], let column = sortColumns(property).first {
            groupColumn = column
            order += ["(\(column) IS NULL)", column]
        }
        for sort in spec.sorts {
            guard let property = catalog.propertiesById[sort.propertyId] else { continue }
            for column in sortColumns(property) {
                order += ["(\(column) IS NULL)", column + (sort.ascending ? "" : " DESC")]
            }
        }
        if let viewId = spec.viewId {
            joins.append("LEFT JOIN db_row_order o ON o.viewId = ? AND o.rowId = p.id")
            joinArguments.append(viewId.databaseText)
            order.append("COALESCE(o.sortKey, p.sortKey)")
        } else {
            order.append("p.sortKey")
        }
        order.append("p.id")
        let sql = """
            SELECT p.id, \(groupColumn) AS groupKey FROM page p
            \(joins.joined(separator: "\n"))
            WHERE \(conditions.joined(separator: " AND "))
            ORDER BY \(order.joined(separator: ", "))
            """
        return (sql, StatementArguments(joinArguments + whereArguments))
    }

    /// Выполнить запрос в чтении.
    public mutating func fetch(in db: Database) throws -> ViewQueryResult {
        let (sql, arguments) = build()
        var ids: [UUID] = []
        var keys: [Double?] = []
        let grouped = spec.groupPropertyId != nil
        let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
        while let row = try rows.next() {
            guard let id = UUID(uuidString: row[0]) else { continue }
            ids.append(id)
            if grouped { keys.append(row[1]) }
        }
        return ViewQueryResult(rowIds: ids, groupKeys: grouped ? keys : nil)
    }

    // MARK: Сортировки

    /// Колонки сравнимого значения свойства (с присоединением нужной таблицы).
    private mutating func sortColumns(_ property: DatabaseProperty) -> [String] {
        switch property.kind {
        case .createdTime: return ["p.createdAt"]
        case .lastEditedTime: return ["p.updatedAt"]
        case .relation: return []
        case .title: return ["\(join(property, table: "db_computed")).sortText"]
        case .formula, .rollup:
            let alias = join(property, table: "db_computed")
            return ["\(alias).sortNumber", "\(alias).sortText"]
        case .checkbox: return ["COALESCE(\(join(property, table: "db_cell")).sortNumber, 0)"]
        default:
            let alias = join(property, table: "db_cell")
            return [Self.isNumeric(property.kind) ? "\(alias).sortNumber" : "\(alias).sortText"]
        }
    }

    private mutating func join(_ property: DatabaseProperty, table: String) -> String {
        let alias = "s\(joins.count)"
        joins.append("LEFT JOIN \(table) \(alias) ON \(alias).rowId = p.id AND \(alias).propertyId = ?")
        joinArguments.append(property.id.databaseText)
        return alias
    }

    static func isNumeric(_ kind: PropertyKind) -> Bool {
        [.number, .date, .select, .status, .multiSelect, .uniqueId, .files, .checkbox].contains(kind)
    }

    // MARK: Фильтр

    private mutating func predicate(_ node: FilterNode) -> String? {
        switch node {
        case .condition(let condition): return predicate(condition)
        case .and(let items), .or(let items):
            let joiner = if case .and = node { " AND " } else { " OR " }
            let parts = items.compactMap { predicate($0) }
            return parts.isEmpty ? nil : "(" + parts.joined(separator: joiner) + ")"
        }
    }

    private mutating func predicate(_ condition: FilterCondition) -> String? {
        guard let property = catalog.propertiesById[condition.propertyId] else { return nil }
        let value = condition.value
        switch property.kind {
        case .title: return textPredicate(property, table: "db_computed", condition.op, value.string)
        case .text, .url, .email, .phone: return textPredicate(property, table: "db_cell", condition.op, value.string)
        case .number, .uniqueId: return numberPredicate(property, table: "db_cell", condition.op, value.number)
        case .checkbox:
            let checked = value.bool ?? false
            return (checked ? "" : "NOT ") + rows(property, "db_cell", "sortNumber = 1")
        case .select, .status:
            var ids = value.array?.compactMap(\.string) ?? value.string.map { [$0] } ?? []
            var op = condition.op
            if op == .isInGroup, let group = value.string.flatMap(StatusGroup.init(rawValue:)) {
                ids = (catalog.options[property.id] ?? []).filter { $0.statusGroup == group }.map(\.id.databaseText)
                op = .is
            }
            switch op {
            case .is, .isNot:
                guard !ids.isEmpty else { return nil }
                return (op == .isNot ? "NOT " : "") + rows(property, "db_cell", "sortText IN (\(placeholders(ids.count)))", ids)
            case .isEmpty: return "NOT " + rows(property, "db_cell", "sortText IS NOT NULL")
            case .isNotEmpty: return rows(property, "db_cell", "sortText IS NOT NULL")
            default: return nil
            }
        case .multiSelect:
            // `sortText` множественного выбора — id вариантов через пробел (сортирует `sortNumber` — место первого):
            // «содержит» — по покрывающему индексу, без чтения строк ячеек.
            let ids = value.array?.compactMap(\.string) ?? value.string.map { [$0] } ?? []
            switch condition.op {
            case .contains, .doesNotContain, .is, .isNot:
                guard !ids.isEmpty else { return nil }
                let any = ids.map { _ in "sortText LIKE ?" }.joined(separator: " OR ")
                let negated = condition.op == .doesNotContain || condition.op == .isNot
                return (negated ? "NOT " : "") + rows(property, "db_cell", "(\(any))", ids.map { "%" + Self.escapedLike($0) + "%" })
            case .isEmpty: return "NOT " + rows(property, "db_cell", "sortText IS NOT NULL AND sortText != ''")
            case .isNotEmpty: return rows(property, "db_cell", "sortText IS NOT NULL AND sortText != ''")
            default: return nil
            }
        case .files:
            switch condition.op {
            case .isEmpty: return "NOT " + rows(property, "db_cell", "value IS NOT NULL AND value != '[]'")
            case .isNotEmpty: return rows(property, "db_cell", "value IS NOT NULL AND value != '[]'")
            default: return nil
            }
        case .date: return datePredicate(column: nil, property: property, table: "db_cell", condition.op, value)
        case .createdTime: return datePredicate(column: "p.createdAt", property: property, table: nil, condition.op, value)
        case .lastEditedTime: return datePredicate(column: "p.updatedAt", property: property, table: nil, condition.op, value)
        case .relation: return relationPredicate(property, condition.op, value)
        case .formula, .rollup:
            if value.number != nil || [.equals, .notEquals, .greaterThan, .lessThan, .greaterThanOrEqual, .lessThanOrEqual].contains(condition.op) {
                return numberPredicate(property, table: "db_computed", condition.op, value.number)
            }
            if let checked = value.bool { return (checked ? "" : "NOT ") + rows(property, "db_computed", "sortNumber = 1") }
            if value.object != nil { return datePredicate(column: nil, property: property, table: "db_computed", condition.op, value) }
            return textPredicate(property, table: "db_computed", condition.op, value.string)
        default:
            return nil
        }
    }

    /// `p.id IN (SELECT rowId FROM <table> WHERE propertyId = ? AND <условие>)` — по индексу свойства.
    private mutating func rows(_ property: DatabaseProperty, _ table: String, _ condition: String, _ arguments: [DatabaseValueConvertible?] = []) -> String {
        whereArguments.append(property.id.databaseText)
        whereArguments += arguments
        return "p.id IN (SELECT rowId FROM \(table) WHERE propertyId = ? AND \(condition))"
    }

    private func placeholders(_ count: Int) -> String { Array(repeating: "?", count: count).joined(separator: ", ") }

    private mutating func textPredicate(_ property: DatabaseProperty, table: String, _ op: FilterOperator, _ text: String?) -> String? {
        let needle = SortableText.make(text ?? "")
        let filled = "sortText IS NOT NULL AND sortText != ''"
        switch op {
        case .isEmpty: return "NOT " + rows(property, table, filled)
        case .isNotEmpty: return rows(property, table, filled)
        default: break
        }
        guard !needle.isEmpty else { return nil }
        switch op {
        case .is: return rows(property, table, "sortText = ?", [needle])
        case .isNot: return "NOT " + rows(property, table, "sortText = ?", [needle])
        case .contains: return rows(property, table, "sortText LIKE ? ESCAPE '\\'", ["%" + Self.escapedLike(needle) + "%"])
        case .doesNotContain: return "NOT " + rows(property, table, "sortText LIKE ? ESCAPE '\\'", ["%" + Self.escapedLike(needle) + "%"])
        case .startsWith: return rows(property, table, "sortText >= ? AND sortText < ?", [needle, needle + "\u{10FFFF}"])
        case .endsWith: return rows(property, table, "sortText LIKE ? ESCAPE '\\'", ["%" + Self.escapedLike(needle)])
        default: return nil
        }
    }

    private mutating func numberPredicate(_ property: DatabaseProperty, table: String, _ op: FilterOperator, _ number: Double?) -> String? {
        switch op {
        case .isEmpty: return "NOT " + rows(property, table, "sortNumber IS NOT NULL")
        case .isNotEmpty: return rows(property, table, "sortNumber IS NOT NULL")
        default: break
        }
        guard let number else { return nil }
        let comparison: String
        switch op {
        case .equals, .is: comparison = "sortNumber = ?"
        case .notEquals, .isNot: return "NOT " + rows(property, table, "sortNumber = ?", [number])
        case .greaterThan: comparison = "sortNumber > ?"
        case .lessThan: comparison = "sortNumber < ?"
        case .greaterThanOrEqual: comparison = "sortNumber >= ?"
        case .lessThanOrEqual: comparison = "sortNumber <= ?"
        default: return nil
        }
        return rows(property, table, comparison, [number])
    }

    /// Дата: значение — `{relative: today|tomorrow|…}`, `{exact: "2026-10-21"}`, `{start, end}` (между) или
    /// `{direction: past|next|this, count, unit: day|week|month|year}` (относительно сегодня).
    private mutating func datePredicate(column: String?, property: DatabaseProperty, table: String?, _ op: FilterOperator,
                                        _ value: JSONValue) -> String? {
        func compare(_ condition: String, _ arguments: [DatabaseValueConvertible?]) -> String {
            if let column {
                whereArguments += arguments.map { ($0 as? Double).map { Date(timeIntervalSince1970: $0) } ?? $0 }
                return condition.replacingOccurrences(of: "sortNumber", with: column)
            }
            return rows(property, table!, condition, arguments)
        }
        switch op {
        case .isEmpty: return column == nil ? "NOT " + rows(property, table!, "sortNumber IS NOT NULL") : nil
        case .isNotEmpty: return column == nil ? rows(property, table!, "sortNumber IS NOT NULL") : "1"
        default: break
        }
        let range: (Date, Date)?
        switch op {
        case .isRelativeToToday: range = relativeRange(value)
        case .isBetween:
            guard let start = day(value["start"] ?? .null), let end = day(value["end"] ?? .null) else { return nil }
            range = (start, calendar.date(byAdding: .day, value: 1, to: end)!)
        default:
            guard let start = day(value) else { return nil }
            range = (start, calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        guard let (start, end) = range else { return nil }
        let a = start.timeIntervalSince1970, b = end.timeIntervalSince1970
        switch op {
        case .is, .isRelativeToToday, .isBetween: return compare("sortNumber >= ? AND sortNumber < ?", [a, b])
        case .isBefore: return compare("sortNumber < ?", [a])
        case .isAfter: return compare("sortNumber >= ?", [b])
        case .isOnOrBefore: return compare("sortNumber < ?", [b])
        case .isOnOrAfter: return compare("sortNumber >= ?", [a])
        default: return nil
        }
    }

    /// Начало дня значения фильтра.
    private func day(_ value: JSONValue) -> Date? {
        let today = calendar.startOfDay(for: now)
        if let relative = value["relative"]?.string {
            let shift: (Calendar.Component, Int) = switch relative {
            case "tomorrow": (.day, 1)
            case "yesterday": (.day, -1)
            case "oneWeekAgo": (.day, -7)
            case "oneWeekFromNow": (.day, 7)
            case "oneMonthAgo": (.month, -1)
            case "oneMonthFromNow": (.month, 1)
            default: (.day, 0)
            }
            return calendar.date(byAdding: shift.0, value: shift.1, to: today)
        }
        guard let text = value["exact"]?.string ?? value.string else { return nil }
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func relativeRange(_ value: JSONValue) -> (Date, Date)? {
        let today = calendar.startOfDay(for: now)
        let count = Int(value["count"]?.number ?? 1)
        let unit: Calendar.Component = switch value["unit"]?.string {
        case "week": .weekOfYear
        case "month": .month
        case "year": .year
        default: .day
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        switch value["direction"]?.string {
        case "past": return (calendar.date(byAdding: unit, value: -count, to: today)!, tomorrow)
        case "next": return (today, calendar.date(byAdding: unit, value: count, to: tomorrow)!)
        default:
            guard let interval = calendar.dateInterval(of: unit, for: now) else { return nil }
            return (interval.start, interval.end)
        }
    }

    private mutating func relationPredicate(_ property: DatabaseProperty, _ op: FilterOperator, _ value: JSONValue) -> String? {
        let targets = value.array?.compactMap(\.string) ?? value.string.map { [$0] } ?? []
        // Связи хранятся у свойства пары с меньшим id (data-model.md, `db_relation_link`): у второго — в обратную сторону.
        let paired = property.config["pairedPropertyId"]?.string.flatMap(UUID.init(uuidString:))
        let stored = paired.map { $0.uuidString < property.id.uuidString } ?? false
        let (linkProperty, own, other) = stored ? (paired!, "targetRowId", "rowId") : (property.id, "rowId", "targetRowId")
        func links(_ extra: String, _ arguments: [DatabaseValueConvertible?]) -> String {
            whereArguments.append(linkProperty.databaseText)
            whereArguments += arguments
            return "p.id IN (SELECT \(own) FROM db_relation_link WHERE propertyId = ? AND isPresent = 1\(extra))"
        }
        switch op {
        case .isEmpty: return "NOT " + links("", [])
        case .isNotEmpty: return links("", [])
        case .contains: return targets.isEmpty ? nil : links(" AND \(other) IN (\(placeholders(targets.count)))", targets)
        case .doesNotContain: return targets.isEmpty ? nil : "NOT " + links(" AND \(other) IN (\(placeholders(targets.count)))", targets)
        default: return nil
        }
    }

    // MARK: Поиск

    /// Поиск по названию и видимым свойствам. Текст ищется в `sortText` (у текстовых типов он и есть текст поиска) —
    /// по покрывающему индексу `(propertyId, sortText)`, без чтения строк ячеек; выбор и статус — по id вариантов,
    /// чьи названия подходят; остальное — по `searchText` (проба R20.2: чтение строк ячеек давало 150 мс на символ).
    private mutating func searchPredicate(_ search: String) -> String {
        let needle = SortableText.make(search)
        let pattern = "%" + Self.escapedLike(needle) + "%"
        var parts: [String] = []
        let properties = spec.searchPropertyIds.compactMap { catalog.propertiesById[$0] } + [catalog.titleProperty].compactMap { $0 }
        var textCells: [String] = [], textComputed: [String] = [], otherCells: [String] = []
        var optionIds: [String] = [], multiOptionIds: [(property: String, id: String)] = []
        for property in properties {
            let id = property.id.databaseText
            switch property.kind {
            case .text, .url, .email, .phone: textCells.append(id)
            case .title, .formula, .rollup: textComputed.append(id)
            case .select, .status, .multiSelect:
                let matching = (catalog.options[property.id] ?? []).filter { SortableText.make($0.name).contains(needle) }.map(\.id.databaseText)
                if property.kind == .multiSelect { multiOptionIds += matching.map { (id, $0) } } else { optionIds += matching }
            case .uniqueId, .files, .number: otherCells.append(id)
            default: break
            }
        }
        func unique(_ ids: [String]) -> [String] { Array(Set(ids)).sorted() }
        if !textCells.isEmpty {
            let ids = unique(textCells)
            parts.append("p.id IN (SELECT rowId FROM db_cell WHERE propertyId IN (\(placeholders(ids.count))) AND sortText LIKE ? ESCAPE '\\')")
            whereArguments += ids + [pattern]
        }
        if !textComputed.isEmpty {
            let ids = unique(textComputed)
            parts.append("p.id IN (SELECT rowId FROM db_computed WHERE propertyId IN (\(placeholders(ids.count))) AND sortText LIKE ? ESCAPE '\\')")
            whereArguments += ids + [pattern]
        }
        if !optionIds.isEmpty {
            parts.append("p.id IN (SELECT rowId FROM db_cell WHERE sortText IN (\(placeholders(optionIds.count))))")
            whereArguments += optionIds
        }
        for (property, option) in multiOptionIds {
            parts.append("p.id IN (SELECT rowId FROM db_cell WHERE propertyId = ? AND sortText LIKE ?)")
            whereArguments += [property, "%" + option + "%"]
        }
        if !otherCells.isEmpty {
            let ids = unique(otherCells)
            parts.append("p.id IN (SELECT rowId FROM db_cell WHERE propertyId IN (\(placeholders(ids.count))) AND searchText LIKE ? ESCAPE '\\')")
            whereArguments += ids + [pattern]
        }
        return parts.isEmpty ? "0" : "(" + parts.joined(separator: " OR ") + ")"
    }

    static func escapedLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}
