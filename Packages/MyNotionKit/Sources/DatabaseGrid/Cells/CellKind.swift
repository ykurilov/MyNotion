import Foundation
import NotesCore

/// Как правится ячейка (contracts/database-ui.md, «Ячейки и клавиши»).
public enum CellEditing: Sendable, Hashable {
    /// Правка на месте: название, текст, число, ссылка, email, телефон.
    case inPlace
    /// Окно правки под ячейкой: выбор, статус, дата, связь, файлы.
    case popup
    /// Щелчок переключает: флажок.
    case toggle
    /// Без правки: формула, сводка, создано, изменено, ID.
    case none
}

/// Тип ячейки в сетке: значок шапки и способ правки. Рисование и редактор типа — файл `Cells/<Тип>Cell.swift`
/// истории, которая вводит тип (research R5).
public struct CellKind: Sendable, Hashable {
    public let kind: PropertyKind
    /// Значок типа (SF Symbols) — близкий к значку Notion 7.39 в шапке и списке типов.
    public let symbol: String
    public let editing: CellEditing
    /// Название типа в списке «+» и «Сменить тип».
    public let title: String

    public static let all: [CellKind] = [
        CellKind(kind: .title, symbol: "textformat", editing: .inPlace, title: "Название"),
        CellKind(kind: .text, symbol: "text.alignleft", editing: .inPlace, title: "Текст"),
        CellKind(kind: .number, symbol: "number", editing: .inPlace, title: "Число"),
        CellKind(kind: .select, symbol: "chevron.down.circle", editing: .popup, title: "Выбор"),
        CellKind(kind: .multiSelect, symbol: "list.bullet", editing: .popup, title: "Множественный выбор"),
        CellKind(kind: .status, symbol: "circle.dotted.circle", editing: .popup, title: "Статус"),
        CellKind(kind: .date, symbol: "calendar", editing: .popup, title: "Дата"),
        CellKind(kind: .files, symbol: "paperclip", editing: .popup, title: "Файлы и медиа"),
        CellKind(kind: .checkbox, symbol: "checkmark.square", editing: .toggle, title: "Флажок"),
        CellKind(kind: .url, symbol: "link", editing: .inPlace, title: "Ссылка"),
        CellKind(kind: .phone, symbol: "phone", editing: .inPlace, title: "Телефон"),
        CellKind(kind: .email, symbol: "at", editing: .inPlace, title: "Email"),
        CellKind(kind: .relation, symbol: "arrow.up.right", editing: .popup, title: "Связь"),
        CellKind(kind: .rollup, symbol: "magnifyingglass", editing: .none, title: "Сводка"),
        CellKind(kind: .formula, symbol: "function", editing: .none, title: "Формула"),
        CellKind(kind: .uniqueId, symbol: "number.square", editing: .none, title: "ID"),
        CellKind(kind: .createdTime, symbol: "clock", editing: .none, title: "Создано"),
        CellKind(kind: .lastEditedTime, symbol: "clock.arrow.circlepath", editing: .none, title: "Изменено"),
    ]

    private static let byKind = Dictionary(uniqueKeysWithValues: all.map { ($0.kind, $0) })

    /// Тип от более новой версии — как формула: без правки.
    public static func `for`(_ kind: PropertyKind) -> CellKind {
        byKind[kind] ?? CellKind(kind: kind, symbol: "questionmark.square", editing: .none, title: kind.rawValue)
    }
}
