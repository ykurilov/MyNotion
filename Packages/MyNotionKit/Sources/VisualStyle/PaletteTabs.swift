#if canImport(AppKit)
import AppKit

extension Palette {
    /// Полоса вкладок в строке светофора — фон боковой панели; активная вкладка — фон страницы
    /// (снимок Notion 7.39, 20.10.2026: 0x202020 и 0x191919 в тёмной теме).
    public static var tabStripBackground: NSColor { sidebarBackground }
    /// Линии между вкладками и под полосой (тёмная тема — 0x2C2C2B, как край панели).
    public static var tabSeparator: NSColor { sidebarEdge }
    /// Название неактивной вкладки, «+», «‹ ›», когда есть куда идти (тёмная — 0xADA9A3).
    public static var tabInactiveTitle: NSColor { windowToolbarIcon }
    /// «‹ ›», когда идти некуда (тёмная — 0x454442; светлая ≈ по снимку).
    public static let tabArrowDisabled = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x45 / 255, green: 0x44 / 255, blue: 0x42 / 255, alpha: 1)
            : NSColor(srgbRed: 0xD3 / 255, green: 0xD1 / 255, blue: 0xCE / 255, alpha: 1)
    }
    /// «×» на вкладке (тёмная — 0x7D7A75).
    public static var tabClose: NSColor { pageHeaderButton }
    /// Рамка окна «Открыть в новой вкладке…» (⌘T): у Notion 7.39 — кольцо 1 0x383836 в тёмной теме (замер 21.10.2026);
    /// в светлой — заметное на белой странице кольцо (проверка T101 № 21: светлая карточка без рамки тонула).
    public static let newTabCardRing = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x38 / 255, green: 0x38 / 255, blue: 0x36 / 255, alpha: 1)
            : NSColor(srgbRed: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 0.12)
    }
}
#endif
