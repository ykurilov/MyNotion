import AppKit
import CoreText
import VisualStyle

/// Текст ячеек Core Text: строки `CTLine` кэшируются по тексту, цвету и начертанию; длинный текст обрезается «…».
@MainActor
final class GridTextRenderer {
    enum Alignment { case left, right }

    private struct Key: Hashable {
        let text: String
        let weight: NSFont.Weight.RawValue
        let width: Int
    }

    private var lines: [Key: CTLine] = [:]
    private var widths: [String: CGFloat] = [:]
    private var fonts: [NSFont.Weight.RawValue: NSFont] = [:]

    private func font(_ weight: NSFont.Weight) -> NSFont {
        if let font = fonts[weight.rawValue] { return font }
        let font = NSFont.systemFont(ofSize: Metrics.DatabaseGrid.fontSize, weight: weight)
        fonts[weight.rawValue] = font
        return font
    }

    func width(_ text: String, size: CGFloat) -> CGFloat {
        if let width = widths[text] { return width }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font(.regular)]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if widths.count > 20_000 { widths.removeAll() }
        widths[text] = width
        return width
    }

    func draw(_ text: String, in rect: CGRect, color: NSColor, alignment: Alignment, weight: NSFont.Weight = .regular, context: CGContext) {
        guard rect.width > 4, !text.isEmpty else { return }
        let key = Key(text: text, weight: weight.rawValue, width: Int(rect.width))
        let line: CTLine
        if let cached = lines[key] {
            line = cached
        } else {
            // Цвет — из контекста (`foregroundColorFromContext`): одна строка служит обеим темам и всем цветам.
            let attributed = NSAttributedString(string: text.replacingOccurrences(of: "\n", with: " "),
                                                attributes: [.font: font(weight), NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
            let full = CTLineCreateWithAttributedString(attributed)
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font(weight),
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
            line = CTLineCreateTruncatedLine(full, Double(rect.width), .end, ellipsis) ?? full
            if lines.count > 20_000 { lines.removeAll() }
            lines[key] = line
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let x = alignment == .right ? rect.maxX - width : rect.minX
        // Вид перевёрнут: Core Text рисует снизу вверх — переворачиваем на время строки.
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.textMatrix = .identity
        context.translateBy(x: x, y: rect.midY + (ascent - descent) / 2)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
