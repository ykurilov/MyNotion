import Foundation
import NotesCore

/// Место пункта меню строки (contracts/database-ui.md, «Строки»), по порядку.
public enum RowMenuSlot: Int, CaseIterable, Comparable, Sendable {
    case findAction, favorite, changeIcon, editProperty, openIn, duplicate, moveTo, trash, footer

    public static func < (lhs: RowMenuSlot, rhs: RowMenuSlot) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Описатель пункта меню строки: место, название, подсказка клавиш. Действие — обработчик окна (US1); пункт без
/// обработчика не показывается.
public struct RowMenuItem: Sendable {
    public let slot: RowMenuSlot
    public let title: String
    public let hint: String?

    public init(slot: RowMenuSlot, title: String, hint: String? = nil) {
        self.slot = slot
        self.title = title
        self.hint = hint
    }

    public static let all: [RowMenuItem] = [
        RowMenuItem(slot: .findAction, title: "Найти действие…"),
        RowMenuItem(slot: .favorite, title: "В избранное"),
        RowMenuItem(slot: .changeIcon, title: "Изменить иконку"),
        RowMenuItem(slot: .editProperty, title: "Изменить свойство"),
        RowMenuItem(slot: .openIn, title: "Открыть в"),
        RowMenuItem(slot: .duplicate, title: "Дублировать", hint: "⌘D"),
        RowMenuItem(slot: .moveTo, title: "Переместить в", hint: "⇧⌘P"),
        RowMenuItem(slot: .trash, title: "Удалить в корзину", hint: "⌫"),
        RowMenuItem(slot: .footer, title: "Изменено"),
    ]

    public static func ordered(_ items: [RowMenuItem]) -> [RowMenuItem] { items.sorted { $0.slot < $1.slot } }
}
