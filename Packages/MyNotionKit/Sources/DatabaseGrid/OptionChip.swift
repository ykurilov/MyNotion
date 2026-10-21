import AppKit
import NotesCore
import VisualStyle

/// Плашка варианта выбора и статуса (contracts/property-types.md, «Цвета вариантов»): название на фоне цвета Notion,
/// скругление и поля сетки. Общая для ячеек, окон выбора, фильтров и групп (US2, US3, US4).
@MainActor
public final class OptionChip: NSView {
    public var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var color: OptionColor { didSet { needsDisplay = true } }

    public init(title: String, color: OptionColor) {
        self.title = title
        self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    static let font = NSFont.systemFont(ofSize: Metrics.DatabaseGrid.chipFontSize)

    /// Размер плашки по названию.
    public static func size(for title: String) -> NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(width) + 2 * Metrics.DatabaseGrid.chipHorizontalPadding, height: Metrics.DatabaseGrid.chipHeight)
    }

    public override var intrinsicContentSize: NSSize { Self.size(for: title) }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: max(0, (bounds.height - Metrics.DatabaseGrid.chipHeight) / 2))
        Self.draw(title: title, color: color, in: rect)
    }

    /// Нарисовать плашку в рамке текущего графического контекста (перевёрнутого).
    public static func draw(title: String, color: OptionColor, in rect: NSRect) {
        let radius = Metrics.DatabaseGrid.chipCornerRadius
        Palette.optionChipBackground(color.rawValue).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.optionChipText, .paragraphStyle: paragraph]
        let textHeight = font.ascender - font.descender
        let textRect = NSRect(x: rect.minX + Metrics.DatabaseGrid.chipHorizontalPadding, y: rect.midY - textHeight / 2,
                              width: rect.width - 2 * Metrics.DatabaseGrid.chipHorizontalPadding, height: textHeight)
        (title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}
