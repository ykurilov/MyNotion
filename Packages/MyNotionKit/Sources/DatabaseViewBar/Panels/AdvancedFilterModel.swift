import Databases
import Foundation
import NotesCore

/// Расширенный фильтр без отрисовки (`notion-advanced-filter-*.png`): строки группы «Где / И ▾ / И», вложенные группы,
/// пункты «•••» строки и правки по ним.
public enum AdvancedFilterModel {
    /// Начало строки: «Где» у первой, меню «И ▾ / Или ▾» у второй (одно на группу), серая связка у остальных.
    public enum Lead: Sendable, Hashable {
        case whereLabel
        case joinerMenu(isOr: Bool)
        case joinerText(isOr: Bool)
    }

    /// Пункт «•••» строки.
    public enum RuleAction: String, Sendable, Hashable, CaseIterable {
        case remove, duplicate, turnIntoGroup

        public var title: String {
            switch self {
            case .remove: "Удалить"
            case .duplicate: "Дублировать"
            case .turnIntoGroup: "Превратить в группу"
            }
        }

        public var icon: String {
            switch self {
            case .remove: "trash"
            case .duplicate: "plus.square.on.square"
            case .turnIntoGroup: "square.dashed"
            }
        }
    }

    public struct Entry: Sendable, Hashable {
        public enum Content: Sendable, Hashable {
            case rule(FilterCondition)
            case group(Group)
        }

        public let path: FilterPath
        public let lead: Lead
        public let content: Content
        public let actions: [RuleAction]
    }

    public struct Group: Sendable, Hashable {
        public let path: FilterPath
        public let isOr: Bool
        public let entries: [Entry]
        /// «+ Добавить правило ▾» предлагает и группу фильтров.
        public let canAddGroup: Bool
    }

    /// Группа по пути (расширенный фильтр — `[k]`); `nil` — там не группа.
    public static func group(at path: FilterPath, in filter: FilterNode?) -> Group? {
        guard let node = FilterEditing.root(filter).node(at: path), node.isGroup else { return nil }
        return group(node, path: path)
    }

    private static func group(_ node: FilterNode, path: FilterPath) -> Group {
        let entries = node.children.enumerated().map { index, child -> Entry in
            let childPath = path + [index]
            let lead: Lead = switch index {
            case 0: .whereLabel
            case 1: .joinerMenu(isOr: node.isOr)
            default: .joinerText(isOr: node.isOr)
            }
            if child.isGroup {
                return Entry(path: childPath, lead: lead, content: .group(group(child, path: childPath)), actions: [.remove, .duplicate])
            }
            let actions: [RuleAction] = FilterEditing.canAddGroup(toGroup: path) ? [.remove, .duplicate, .turnIntoGroup] : [.remove, .duplicate]
            return Entry(path: childPath, lead: lead, content: .rule(child.condition!), actions: actions)
        }
        return Group(path: path, isOr: node.isOr, entries: entries, canAddGroup: FilterEditing.canAddGroup(toGroup: path))
    }

    public static func apply(_ action: RuleAction, at path: FilterPath, in filter: FilterNode?) -> FilterNode? {
        switch action {
        case .remove: FilterEditing.remove(at: path, in: filter)
        case .duplicate: FilterEditing.duplicate(at: path, in: filter)
        case .turnIntoGroup: FilterEditing.turnIntoGroup(at: path, in: filter)
        }
    }

    /// «И» / «Или» и подсказки меню связки.
    public static func joinerTitle(isOr: Bool) -> String { isOr ? "Или" : "И" }
    public static let joinerChoices: [(isOr: Bool, title: String, caption: String)] = [
        (false, "И", "Подходят все правила"), (true, "Или", "Подходит хотя бы одно"),
    ]

    /// «+ Расширенный фильтр» в списке «Фильтр по…»: расширенный фильтр уже есть — новое правило в нём, иначе — новая
    /// группа «И» в конце корня. Возвращает путь расширенного фильтра.
    public static func addingAdvanced(_ rule: FilterCondition, to filter: FilterNode?) -> (FilterNode?, FilterPath) {
        if let path = FilterEditing.advancedPath(in: filter) {
            return (FilterEditing.addRule(rule, toGroup: path, in: filter), path)
        }
        let items = FilterEditing.root(filter).children + [.and([.condition(rule)])]
        return (.and(items), [items.count - 1])
    }

    /// Новое правило: первое свойство по алфавиту (у Notion — «Название») с условием по умолчанию.
    public static func newRule(catalog: DatabaseCatalog) -> FilterCondition? {
        (catalog.titleProperty ?? PropertyChoices.forFilter(catalog).first).map(FilterEditing.defaultCondition(for:))
    }

    /// Раскладка окна без значений текста и чисел: окно пересобирается, только если она сменилась (поле в фокусе
    /// не теряет ввод, пока его значение пишется).
    public static func layoutSignature(_ node: FilterNode?, catalog: DatabaseCatalog) -> FilterNode? {
        guard let node else { return nil }
        switch node {
        case .condition(var condition):
            if let property = catalog.propertiesById[condition.propertyId], [.text, .number, .list].contains(FilterValueKind(property)) {
                condition.value = .null
            }
            return .condition(condition)
        case .and(let items): return .and(items.compactMap { layoutSignature($0, catalog: catalog) })
        case .or(let items): return .or(items.compactMap { layoutSignature($0, catalog: catalog) })
        }
    }
}
