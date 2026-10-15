import AppKit

/// Шрифты и строки по contracts/visual-style.md. Шрифт — системный (San Francisco), код — SF Mono.
public enum Typography {
    public static let pageTitle = TextLineStyle(fontSize: 40, lineHeight: 48, weight: .bold)
    public static let breadcrumb = TextLineStyle(fontSize: 14, lineHeight: 20, weight: .regular)
    public static let sidebarRow = TextLineStyle(fontSize: 14, lineHeight: 20, weight: .regular)
    public static let sidebarGroupHeader = TextLineStyle(fontSize: 12, lineHeight: 16, weight: .medium)
    public static let pageLinkTitle = TextLineStyle(fontSize: 16, lineHeight: 24, weight: .medium)
    public static let popupMenuTitle = TextLineStyle(fontSize: 14, lineHeight: 20, weight: .regular)
    /// Заголовок раздела меню «/» и быстрые символы справа в строке.
    public static let popupMenuSectionHeader = TextLineStyle(fontSize: 12, lineHeight: 16, weight: .medium)
    public static let popupMenuShortcut = TextLineStyle(fontSize: 12, lineHeight: 16, weight: .regular)

    /// Жирный в строке — 600.
    public static let inlineBoldWeight = NSFont.Weight.semibold
    /// Код в строке — SF Mono на 85 % размера текста.
    public static let inlineCodeScale: CGFloat = 0.85

    public static func line(for style: BlockTextStyle) -> TextLineStyle {
        switch style {
        case .paragraph, .listItem: TextLineStyle(fontSize: 16, lineHeight: 24, weight: .regular)
        case .heading1: TextLineStyle(fontSize: 30, lineHeight: 39, weight: .semibold)
        case .heading2: TextLineStyle(fontSize: 24, lineHeight: 31.2, weight: .semibold)
        case .heading3: TextLineStyle(fontSize: 20, lineHeight: 26, weight: .semibold)
        }
    }

    public static func inlineCodeFont(forTextSize size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size * inlineCodeScale, weight: .regular)
    }
}

/// Вид текста блока. Пункты списков и чекбоксы пишутся как абзац.
public enum BlockTextStyle: Sendable, CaseIterable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case listItem
}

public struct TextLineStyle: Sendable, Hashable {
    public let fontSize: CGFloat
    public let lineHeight: CGFloat
    public let weight: NSFont.Weight

    public var font: NSFont { .systemFont(ofSize: fontSize, weight: weight) }

    /// Абзац с ровной высотой строки, как в Notion.
    public var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }
}
