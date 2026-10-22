import AppKit
import CoreText
import VisualStyle

/// Перенос текста в ячейке (Q1, «Переносить текст»): высота строки — по самому высокому перенесённому тексту, текст —
/// несколькими строками от верха ячейки. Мерить можно с любой очереди (порции строк читаются в фоне).
enum WrappedText {
    static let verticalPadding: CGFloat = 7
    /// Первая строка текста стоит там же, где текст обычной ячейки.
    static let lineHeight: CGFloat = 20

    nonisolated static func attributed(_ text: String, weight: NSFont.Weight) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: Metrics.DatabaseGrid.fontSize, weight: weight), .paragraphStyle: style,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ])
    }

    /// Высота строки таблицы для текста в колонке ширины `width` (не ниже обычной).
    nonisolated static func rowHeight(_ text: String, width: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        guard !text.isEmpty, width > 8 else { return Metrics.DatabaseGrid.rowHeight }
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, weight: weight))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        return max(Metrics.DatabaseGrid.rowHeight, ceil(size.height) + 2 * verticalPadding - 1)
    }

    private struct FrameKey: Hashable {
        let text: String
        let width: Int
        let height: Int
        let weight: CGFloat
        let right: Bool
    }

    /// Разложенный текст по строке и ширине: прокрутка рисует те же ячейки снова — раскладка Core Text не повторяется.
    @MainActor private static var frames: [FrameKey: CTFrame] = [:]

    /// Нарисовать в перевёрнутом виде от верха `rect`.
    @MainActor
    static func draw(_ text: String, in rect: CGRect, color: NSColor, weight: NSFont.Weight, alignment: NSTextAlignment, context: CGContext) {
        guard !text.isEmpty, rect.width > 8 else { return }
        let height = rect.height - 2 * verticalPadding + 2
        let key = FrameKey(text: text, width: Int(rect.width), height: Int(height), weight: weight.rawValue, right: alignment == .right)
        let frame: CTFrame
        if let cached = frames[key] {
            frame = cached
        } else {
            frame = makeFrame(text, width: rect.width, height: height, weight: weight, alignment: alignment)
            if frames.count > 4_000 { frames.removeAll() }
            frames[key] = frame
        }
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.textMatrix = .identity
        // Core Text рисует снизу вверх: рамка — в перевёрнутых координатах полосы текста.
        context.translateBy(x: rect.minX, y: rect.minY + verticalPadding - 1 + height)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private static func makeFrame(_ text: String, width: CGFloat, height: CGFloat, weight: NSFont.Weight, alignment: NSTextAlignment) -> CTFrame {
        let attributed = NSMutableAttributedString(attributedString: attributed(text, weight: weight))
        if alignment == .right, let style = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           let right = style.mutableCopy() as? NSMutableParagraphStyle {
            right.alignment = .right
            attributed.addAttribute(.paragraphStyle, value: right, range: NSRange(location: 0, length: attributed.length))
        }
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
        return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
    }
}
