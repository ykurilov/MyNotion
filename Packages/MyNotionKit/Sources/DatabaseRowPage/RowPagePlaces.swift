import Foundation

/// Место на странице строки (contracts/database-ui.md, «Страница строки»), сверху вниз.
public enum RowPageSlot: Int, CaseIterable, Comparable, Sendable {
    /// Свойства под названием (место «под названием» шапки 003).
    case properties
    case addProperty
    /// Пустое тело: строки шаблонов базы (места 003 `TemplateRows`).
    case emptyBodyTemplates
    /// Кнопки просмотра сбоку и по центру: «»» и «⤢».
    case peekControls

    public static func < (lhs: RowPageSlot, rhs: RowPageSlot) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Описатель места страницы строки: вид делает история (US1 — свойства и просмотр, US6 — шаблоны).
public struct RowPagePlace: Sendable {
    public let slot: RowPageSlot
    public let title: String

    public init(slot: RowPageSlot, title: String) {
        self.slot = slot
        self.title = title
    }

    public static let all: [RowPagePlace] = [
        RowPagePlace(slot: .properties, title: "Свойства"),
        RowPagePlace(slot: .addProperty, title: "Добавить свойство"),
        RowPagePlace(slot: .emptyBodyTemplates, title: "Шаблоны"),
        RowPagePlace(slot: .peekControls, title: "Просмотр"),
    ]

    public static func ordered(_ places: [RowPagePlace]) -> [RowPagePlace] { places.sorted { $0.slot < $1.slot } }
}
