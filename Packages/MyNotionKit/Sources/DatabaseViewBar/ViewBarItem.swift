import Foundation

/// Место кнопки справа в строке вида (contracts/database-ui.md, «Полностраничная база»), по порядку.
public enum ViewBarSlot: Int, CaseIterable, Comparable, Sendable {
    case filter, sort, search, openFullPage, settings, create

    public static func < (lhs: ViewBarSlot, rhs: ViewBarSlot) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Описатель кнопки строки вида: место, значок, подсказка. Кнопку делает история (US3 — фильтр, сортировка, поиск,
/// настройки; US1 — ⤢ и «Создать»; US6 — «Создать ▾»).
public struct ViewBarItem: Sendable {
    public let slot: ViewBarSlot
    public let symbol: String
    public let tooltip: String
    /// Только у встроенной базы (⤢ — открыть на всё окно).
    public let inlineOnly: Bool

    public init(slot: ViewBarSlot, symbol: String, tooltip: String, inlineOnly: Bool = false) {
        self.slot = slot
        self.symbol = symbol
        self.tooltip = tooltip
        self.inlineOnly = inlineOnly
    }

    public static let all: [ViewBarItem] = [
        ViewBarItem(slot: .filter, symbol: "line.3.horizontal.decrease", tooltip: "Фильтр"),
        ViewBarItem(slot: .sort, symbol: "arrow.up.arrow.down", tooltip: "Сортировка"),
        ViewBarItem(slot: .search, symbol: "magnifyingglass", tooltip: "Поиск"),
        ViewBarItem(slot: .openFullPage, symbol: "arrow.up.left.and.arrow.down.right", tooltip: "Открыть на всё окно", inlineOnly: true),
        ViewBarItem(slot: .settings, symbol: "slider.horizontal.3", tooltip: "Настройки вида"),
        ViewBarItem(slot: .create, symbol: "plus", tooltip: "Создать"),
    ]

    public static func ordered(_ items: [ViewBarItem], isInline: Bool) -> [ViewBarItem] {
        items.filter { isInline || !$0.inlineOnly }.sorted { $0.slot < $1.slot }
    }
}
