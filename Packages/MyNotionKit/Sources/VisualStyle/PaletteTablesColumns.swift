import AppKit

extension Palette {
    /// Рамка ячейки, которую правят, и выделенных ячеек таблицы — синий Notion в обеих темах.
    public static let tableActiveCell = NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 1)
    /// Фон строки и столбца заголовков таблицы — серый фон Notion.
    public static var tableHeaderBackground: NSColor { notionBackground(.gray) ?? hoverBackground }
}
