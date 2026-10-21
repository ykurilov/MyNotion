import Foundation
import NotesCore

// MARK: Фильтр

/// Место узла в дереве фильтра: номера детей от корня (`[]` — корень).
public typealias FilterPath = [Int]

/// Правка дерева фильтра (contracts/property-types.md, «Условия фильтра»): корень — группа «И»; его условия — плашки
/// простого фильтра, его группа — расширенный фильтр («N правил»). Правки чистые: вид записывает итог одной операцией.
extension FilterNode {
    /// Детей группы; у условия — нет.
    public var children: [FilterNode] {
        switch self {
        case .condition: []
        case .and(let items), .or(let items): items
        }
    }

    public var isGroup: Bool { if case .condition = self { false } else { true } }
    public var isOr: Bool { if case .or = self { true } else { false } }

    public var condition: FilterCondition? { if case .condition(let condition) = self { condition } else { nil } }

    /// Группа с той же связкой и другими детьми.
    func with(children: [FilterNode]) -> FilterNode {
        switch self {
        case .condition: self
        case .and: .and(children)
        case .or: .or(children)
        }
    }

    /// Узел по пути.
    public func node(at path: FilterPath) -> FilterNode? {
        guard let first = path.first else { return self }
        let items = children
        guard items.indices.contains(first) else { return nil }
        return items[first].node(at: Array(path.dropFirst()))
    }

    /// Заменить узел по пути (`nil` — убрать его).
    public func replacing(at path: FilterPath, with node: FilterNode?) -> FilterNode? {
        guard let first = path.first else { return node }
        var items = children
        guard items.indices.contains(first) else { return self }
        if let replaced = items[first].replacing(at: Array(path.dropFirst()), with: node) { items[first] = replaced } else { items.remove(at: first) }
        return with(children: items)
    }

    /// Число условий во всём дереве («N правил» у расширенного фильтра).
    public var ruleCount: Int {
        switch self {
        case .condition: 1
        case .and(let items), .or(let items): items.reduce(0) { $0 + $1.ruleCount }
        }
    }

    /// Все условия по порядку.
    public var conditions: [FilterCondition] {
        switch self {
        case .condition(let condition): [condition]
        case .and(let items), .or(let items): items.flatMap(\.conditions)
        }
    }
}

/// Правки фильтра вида, как в окнах Notion: плашки простого фильтра в корне, расширенный — группа в корне.
public enum FilterEditing {
    /// Глубже двух групп внутри расширенного фильтра группу не добавить (Notion 7.39, ≈ 2 уровня).
    public static let maxGroupDepth = 2

    /// Корень всегда группа «И»: одно условие или чужое дерево оборачиваются.
    public static func root(_ filter: FilterNode?) -> FilterNode {
        guard let filter else { return .and([]) }
        if case .and = filter { return filter }
        return .and([filter])
    }

    /// Пустое дерево хранится как «нет фильтра».
    public static func normalized(_ root: FilterNode) -> FilterNode? {
        root.children.isEmpty ? nil : root
    }

    /// Новая плашка простого фильтра в конце корня; возвращает её путь.
    public static func addSimple(_ condition: FilterCondition, to filter: FilterNode?) -> (FilterNode, FilterPath) {
        let root = root(filter)
        let items = root.children + [.condition(condition)]
        return (.and(items), [items.count - 1])
    }

    /// Новое правило в группе `groupPath` (у расширенного — внизу списка).
    public static func addRule(_ condition: FilterCondition, toGroup groupPath: FilterPath, in filter: FilterNode?) -> FilterNode? {
        add(.condition(condition), toGroup: groupPath, in: filter)
    }

    /// Новая вложенная группа «И» с одним правилом («+ Добавить группу фильтров»).
    public static func addGroup(_ condition: FilterCondition, toGroup groupPath: FilterPath, in filter: FilterNode?) -> FilterNode? {
        guard canAddGroup(toGroup: groupPath) else { return filter }
        return add(.and([.condition(condition)]), toGroup: groupPath, in: filter)
    }

    /// Можно ли вложить группу в группу `groupPath` (корень — `[]`, расширенный фильтр — `[k]`).
    /// Уровень группы — длина её пути: корень 0, расширенный фильтр 1, вложенная в него 2.
    public static func canAddGroup(toGroup groupPath: FilterPath) -> Bool { groupPath.count < maxGroupDepth }

    private static func add(_ node: FilterNode, toGroup groupPath: FilterPath, in filter: FilterNode?) -> FilterNode? {
        let root = root(filter)
        guard let group = root.node(at: groupPath), group.isGroup else { return filter }
        return root.replacing(at: groupPath, with: group.with(children: group.children + [node]))
    }

    /// «Удалить фильтр» у плашки или «Удалить» у правила; пустая группа уходит вместе с последним правилом.
    public static func remove(at path: FilterPath, in filter: FilterNode?) -> FilterNode? {
        guard !path.isEmpty else { return nil }
        var root = root(filter).replacing(at: path, with: nil) ?? .and([])
        // Опустевшие группы выше по пути — тоже прочь (кроме корня).
        var parent = Array(path.dropLast())
        while !parent.isEmpty, let group = root.node(at: parent), group.isGroup, group.children.isEmpty {
            root = root.replacing(at: parent, with: nil) ?? .and([])
            parent.removeLast()
        }
        return normalized(root)
    }

    /// «Дублировать» правило или группу — копия сразу ниже.
    public static func duplicate(at path: FilterPath, in filter: FilterNode?) -> FilterNode? {
        guard let last = path.last else { return filter }
        let root = root(filter)
        let parentPath = Array(path.dropLast())
        guard let parent = root.node(at: parentPath), let node = root.node(at: path) else { return filter }
        var items = parent.children
        items.insert(node, at: last + 1)
        return root.replacing(at: parentPath, with: parent.with(children: items))
    }

    /// «Превратить в группу»: правило становится группой «И» с ним одним.
    public static func turnIntoGroup(at path: FilterPath, in filter: FilterNode?) -> FilterNode? {
        let root = root(filter)
        guard let node = root.node(at: path), !node.isGroup, canAddGroup(toGroup: Array(path.dropLast())) else { return filter }
        return root.replacing(at: path, with: .and([node]))
    }

    /// «И ▾» / «Или ▾» второй строки группы — связка всей группы.
    public static func setJoiner(or: Bool, ofGroup groupPath: FilterPath, in filter: FilterNode?) -> FilterNode? {
        let root = root(filter)
        guard let group = root.node(at: groupPath), group.isGroup, group.isOr != or else { return filter }
        let items = group.children
        return root.replacing(at: groupPath, with: or ? .or(items) : .and(items))
    }

    /// Правка условия по пути (свойство, условие, значение).
    public static func update(at path: FilterPath, in filter: FilterNode?, _ edit: (inout FilterCondition) -> Void) -> FilterNode? {
        let root = root(filter)
        guard var condition = root.node(at: path)?.condition else { return filter }
        edit(&condition)
        return root.replacing(at: path, with: .condition(condition))
    }

    /// «В расширенный фильтр»: плашка уходит правилом в расширенный фильтр (его нет — он создаётся на её месте).
    /// Возвращает путь расширенного фильтра.
    public static func moveToAdvanced(at path: FilterPath, in filter: FilterNode?) -> (FilterNode?, FilterPath) {
        let root = root(filter)
        guard path.count == 1, let node = root.node(at: path), !node.isGroup else { return (filter, advancedPath(in: filter) ?? []) }
        if let advanced = advancedPath(in: filter), let group = root.node(at: advanced) {
            var items = root.children
            items[advanced[0]] = group.with(children: group.children + [node])
            items.remove(at: path[0])
            let shifted = advanced[0] > path[0] ? advanced[0] - 1 : advanced[0]
            return (.and(items), [shifted])
        }
        return (root.replacing(at: path, with: .and([node])), path)
    }

    /// Путь расширенного фильтра — первая группа в корне.
    public static func advancedPath(in filter: FilterNode?) -> FilterPath? {
        root(filter).children.firstIndex(where: \.isGroup).map { [$0] }
    }

    /// Условие по умолчанию для свойства (первое из меню типа; у флажка — «отмечен»).
    public static func defaultCondition(for property: DatabaseProperty) -> FilterCondition {
        let type = PropertyTypes.type(for: property.kind)
        let op = type.filterOperators.first ?? .contains
        let value: JSONValue = property.kind == .checkbox ? .bool(true) : .null
        return FilterCondition(propertyId: property.id, op: op, value: value)
    }
}

// MARK: Сортировка

extension SortSpec {
    public var json: JSONValue {
        ["propertyId": .string(propertyId.databaseText), "direction": .string(ascending ? "ascending" : "descending")]
    }
}

extension DatabaseView {
    /// Сортировки вида по порядку уровней.
    public var sortSpecs: [SortSpec] { sorts.array?.compactMap(SortSpec.init(json:)) ?? [] }
    public var filterNode: FilterNode? { FilterNode(json: filter) }
    public var groupSettings: GroupSettings? { GroupSettings(json: group) }
    public var layout: ViewLayoutOptions { ViewLayoutOptions(json: layoutOptions) }
    /// Вид удалён («Удалить вид»): запись остаётся следом для синхронизации (data-model.md, у вида нет своего поля).
    public var isDeleted: Bool { layoutOptions[ViewLayoutOptions.deletedAtKey].map { $0 != .null } ?? false }

    /// Колонка свойства: перенос текста и итог.
    public func column(_ propertyId: UUID) -> JSONValue? { DatabaseColumns.entry(propertyId, in: columns) }
    public func wraps(_ propertyId: UUID) -> Bool { layout.wrapAllContent || column(propertyId)?["wrap"]?.bool == true }
    public func calculation(of propertyId: UUID) -> Calculation? {
        column(propertyId)?["calculation"]?.string.flatMap(Calculation.init(rawValue:))
    }
}

// MARK: Группировка

/// Порядок групп (Notion «Sort»): вручную, по алфавиту, в обратном порядке.
public enum GroupSort: String, Sendable, Hashable, CaseIterable {
    case manual, alphabetical, reverseAlphabetical
}

/// Состояние группы в виде: скрыта (глаз), свёрнута (▾); порядок списка — ручной порядок групп.
public struct GroupState: Sendable, Hashable {
    public var key: String
    public var isHidden: Bool
    public var isCollapsed: Bool

    public init(key: String, isHidden: Bool = false, isCollapsed: Bool = false) {
        self.key = key
        self.isHidden = isHidden
        self.isCollapsed = isCollapsed
    }

    init?(json: JSONValue) {
        guard let key = json["key"]?.string else { return nil }
        self.init(key: key, isHidden: json["isHidden"]?.bool ?? false, isCollapsed: json["isCollapsed"]?.bool ?? false)
    }

    var json: JSONValue { ["key": .string(key), "isHidden": .bool(isHidden), "isCollapsed": .bool(isCollapsed)] }
}

/// Группировка вида (data-model.md, `db_view.group`). Ключ группы «Нет …» — пустая строка.
public struct GroupSettings: Sendable, Hashable {
    public var propertyId: UUID
    /// Шаг: у даты `day|week|month|year|relative`, у числа `{from, to, step}`, у статуса `group` — по группам статуса.
    public var bucket: JSONValue?
    public var groupSort: GroupSort
    public var groups: [GroupState]
    public var hideEmpty: Bool
    /// Неизвестные ключи (от новой версии) сохраняются.
    private var extra: [String: JSONValue]

    public static let emptyKey = ""

    public init(propertyId: UUID, bucket: JSONValue? = nil, groupSort: GroupSort = .manual, groups: [GroupState] = [], hideEmpty: Bool = true) {
        self.propertyId = propertyId
        self.bucket = bucket
        self.groupSort = groupSort
        self.groups = groups
        self.hideEmpty = hideEmpty
        extra = [:]
    }

    public init?(json: JSONValue?) {
        guard let json, let id = json["propertyId"]?.string.flatMap(UUID.init(uuidString:)) else { return nil }
        self.init(propertyId: id, bucket: json["bucket"].flatMap { $0 == .null ? nil : $0 },
                  groupSort: json["groupSort"]?.string.flatMap(GroupSort.init(rawValue:)) ?? .manual,
                  groups: json["groups"]?.array?.compactMap(GroupState.init(json:)) ?? [], hideEmpty: json["hideEmpty"]?.bool ?? true)
        extra = (json.object ?? [:]).filter { !Self.knownKeys.contains($0.key) }
    }

    private static let knownKeys: Set<String> = ["propertyId", "bucket", "groupSort", "groups", "hideEmpty"]

    public var json: JSONValue {
        var object = extra
        object["propertyId"] = .string(propertyId.databaseText)
        object["bucket"] = bucket ?? .null
        object["groupSort"] = .string(groupSort.rawValue)
        object["groups"] = .array(groups.map(\.json))
        object["hideEmpty"] = .bool(hideEmpty)
        return .object(object)
    }

    public func state(of key: String) -> GroupState { groups.first { $0.key == key } ?? GroupState(key: key) }

    /// Правка состояния группы (её нет в списке — встаёт в конец).
    public mutating func update(_ key: String, _ edit: (inout GroupState) -> Void) {
        if let index = groups.firstIndex(where: { $0.key == key }) {
            edit(&groups[index])
        } else {
            var state = GroupState(key: key)
            edit(&state)
            groups.append(state)
        }
    }
}

// MARK: Раскладка

/// Настройки раскладки вида (data-model.md, `layoutOptions`): как открывать строки, предел загрузки, перенос всего текста.
public struct ViewLayoutOptions: Sendable, Hashable {
    public var openRowsIn: RowOpenMode
    public var loadLimit: Int
    public var wrapAllContent: Bool

    public static let loadLimits = [10, 25, 50, 100]
    static let deletedAtKey = "deletedAt"

    public init(json: JSONValue) {
        openRowsIn = json["openRowsIn"]?.string.flatMap(RowOpenMode.init(rawValue:)) ?? .sidePeek
        loadLimit = json["loadLimit"]?.number.map(Int.init) ?? 50
        wrapAllContent = json["wrapAllContent"]?.bool ?? false
    }
}
