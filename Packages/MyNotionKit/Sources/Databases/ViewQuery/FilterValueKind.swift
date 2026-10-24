import Foundation
import NotesCore

/// Какое значение у условия фильтра свойства (contracts/property-types.md, «Условия фильтра»): у формулы и сводки — по
/// типу итога (`config.resultType`), у остальных — по типу свойства.
public enum FilterValueKind: Sendable, Hashable {
    case text, number, options, checkbox, date, list, relation, files

    public init(_ property: DatabaseProperty) {
        switch property.kind {
        case .title, .text, .url, .email, .phone: self = .text
        case .number, .uniqueId: self = .number
        case .select, .status, .multiSelect: self = .options
        case .checkbox: self = .checkbox
        case .date, .createdTime, .lastEditedTime: self = .date
        case .relation: self = .relation
        case .files: self = .files
        default:
            self = switch property.config["resultType"]?.string {
            case "number": .number
            case "checkbox": .checkbox
            case "date": .date
            case "list": .list
            default: .text
            }
        }
    }
}

extension FilterEditing {
    /// Условия в меню окна фильтра по порядку Notion; у формулы и сводки — по типу итога.
    public static func operators(for property: DatabaseProperty) -> [FilterOperator] {
        guard property.kind == .formula || property.kind == .rollup else { return PropertyTypes.type(for: property.kind).filterOperators }
        return switch FilterValueKind(property) {
        case .number: FilterOperator.numberOperators
        case .checkbox: [.is]
        case .date: FilterOperator.dateOperators
        case .list: [.contains, .doesNotContain, .isEmpty, .isNotEmpty]
        default: FilterOperator.textOperators
        }
    }
}
