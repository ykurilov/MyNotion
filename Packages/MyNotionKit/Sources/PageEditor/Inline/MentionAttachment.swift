import AppKit
import CoreText
import NotesCore
import VisualStyle

/// Атом в строке — знак U+FFFC с картинкой вместо вида (research R12): сотни упоминаний на странице не создают видов.
/// Картинка рисуется заново при каждом показе по справочнику `PageTextView`, поэтому переименование видно сразу.
class InlineAtomAttachment: NSTextAttachment, @unchecked Sendable {
    let style: InlineStyle

    init(style: InlineStyle) {
        self.style = style
        super.init(data: nil, ofType: nil)
        // Без своей картинки TextKit 2 вложение не рисует: заглушка, настоящую даёт `image(for:…)`.
        allowsTextAttachmentView = false
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    /// Вложение для атома; у формул (US4) своё — пока нет.
    static func make(for style: InlineStyle) -> InlineAtomAttachment? {
        switch style {
        case .mention: MentionAttachment(style: style)
        case .date: DateMentionAttachment(style: style)
        case .equation: InlineEquationAttachment(style: style)
        default: nil
        }
    }

    /// Что нарисовать: куски строки по порядку. Зовётся на главном потоке.
    @MainActor
    func pieces(in textView: PageTextView?, font: NSFont) -> [AtomPiece] { [] }

    @MainActor
    func size(in textView: PageTextView?, font: NSFont? = nil) -> CGSize {
        let font = font ?? Self.defaultFont
        let width = pieces(in: textView, font: font).reduce(0) { $0 + $1.width }
        return CGSize(width: ceil(width), height: ceil(font.ascender - font.descender))
    }

    static var defaultFont: NSFont { Typography.line(for: .paragraph).font }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        nonisolated(unsafe) let font = attributes[.font] as? NSFont ?? Self.defaultFont
        nonisolated(unsafe) let attachment = self
        nonisolated(unsafe) let container = textContainer
        let size = MainActor.assumeIsolated { attachment.size(in: container?.textView as? PageTextView, font: font) }
        // Нижний край — по нижнему выносу шрифта: базовая линия атома совпадает с текстом вокруг.
        return CGRect(x: 0, y: font.descender, width: size.width, height: size.height)
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? {
        nonisolated(unsafe) let font = attributes[.font] as? NSFont ?? Self.defaultFont
        nonisolated(unsafe) let attachment = self
        nonisolated(unsafe) let container = textContainer
        return MainActor.assumeIsolated {
            let textView = container?.textView as? PageTextView
            let pieces = attachment.pieces(in: textView, font: font)
            let appearance = textView?.effectiveAppearance ?? NSAppearance.currentDrawing()
            return NSImage(size: bounds.size, flipped: false) { _ in
                appearance.performAsCurrentDrawingAppearance {
                    var x: CGFloat = 0
                    for piece in pieces {
                        piece.draw(atX: x, baseline: -font.descender, font: font)
                        x += piece.width
                    }
                }
                return true
            }
        }
    }
}

/// Кусок картинки атома: текст, значок или пробел.
struct AtomPiece {
    enum Content {
        case text(String, font: NSFont, color: NSColor, underline: NSColor?, strikethrough: Bool)
        case image(NSImage, size: CGFloat, color: NSColor?)
        case space(CGFloat)
    }

    let content: Content

    static func text(_ string: String, font: NSFont, color: NSColor, underline: NSColor? = nil, strikethrough: Bool = false) -> AtomPiece {
        AtomPiece(content: .text(string, font: font, color: color, underline: underline, strikethrough: strikethrough))
    }

    var width: CGFloat {
        switch content {
        case .text(let string, let font, _, _, _): CGFloat(CTLineGetTypographicBounds(Self.line(string, font: font), nil, nil, nil))
        case .image(_, let size, _): size
        case .space(let width): width
        }
    }

    static func line(_ string: String, font: NSFont) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }

    /// Нарисовать с базовой линией `baseline` (координаты снизу вверх).
    func draw(atX x: CGFloat, baseline: CGFloat, font: NSFont) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        switch content {
        case .text(let string, let pieceFont, let color, let underline, let strikethrough):
            let line = Self.line(string, font: pieceFont)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: baseline)
            context.setFillColor(color.cgColor)
            CTLineDraw(line, context)
            context.restoreGState()
            if let underline {
                underline.setFill()
                CGRect(x: x, y: baseline - 2, width: width, height: 1).fill()
            }
            if strikethrough {
                color.setFill()
                CGRect(x: x, y: baseline + pieceFont.xHeight / 2, width: width, height: 1).fill()
            }
        case .image(let image, let size, let color):
            let rect = CGRect(x: x, y: baseline + font.capHeight / 2 - size / 2, width: size, height: size)
            if let color, let tinted = image.copy() as? NSImage {
                tinted.isTemplate = true
                let filled = NSImage(size: tinted.size, flipped: false) { bounds in
                    tinted.draw(in: bounds)
                    color.set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                filled.draw(in: rect)
            } else {
                image.draw(in: rect)
            }
        case .space:
            break
        }
    }
}

/// Упоминание страницы (contracts/blocks-and-keys.md, «Упоминания»): иконка 1 em и название с жирностью 500,
/// подчёркнутое цветом border. Корзина — серое зачёркнутое «Удалённая страница», страницы ещё нет — серое
/// «Страница загружается».
final class MentionAttachment: InlineAtomAttachment, @unchecked Sendable {
    var pageId: UUID? {
        if case .mention(let id) = style { id } else { nil }
    }

    @MainActor
    override func pieces(in textView: PageTextView?, font: NSFont) -> [AtomPiece] {
        guard let pageId else { return [] }
        let shown = (textView?.mentionDirectory ?? MentionDirectory()).display(of: pageId)
        let titleFont = NSFont.systemFont(ofSize: font.pointSize, weight: .medium)
        let iconSize = font.pointSize
        var result: [AtomPiece] = []
        switch shown.state {
        case .page:
            if let icon = shown.icon, !icon.isEmpty {
                result.append(.text(icon, font: NSFont.systemFont(ofSize: font.pointSize * 0.9), color: Palette.textPrimary))
            } else {
                result.append(AtomPiece(content: .image(DocumentGlyph.image(size: iconSize, color: Palette.textSecondary),
                                                        size: iconSize, color: nil)))
            }
            result.append(AtomPiece(content: .space(font.pointSize * 0.25)))
            result.append(.text(shown.title, font: titleFont, color: Palette.textPrimary, underline: Palette.border))
        case .deleted:
            result.append(.text(shown.title, font: titleFont, color: Palette.textSecondary, strikethrough: true))
        case .loading:
            result.append(.text(shown.title, font: titleFont, color: Palette.textSecondary))
        }
        return result
    }
}
