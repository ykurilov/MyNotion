import AppKit
import MathRendering
import NotesCore
import VisualStyle

/// Формула в строке (research R6): знак U+FFFC с оформлением `equation(запись)`, на экране — картинка формулы
/// по базовой линии текста. Пустая — серое «Новая формула», ошибка — красное «Неверная формула».
final class InlineEquationAttachment: InlineAtomAttachment, @unchecked Sendable {
    var latex: String {
        if case .equation(let latex) = style { latex } else { "" }
    }

    /// Формула чуть крупнее текста вокруг: так её буквы одного роста с ним (как у KaTeX в Notion).
    static let scale: CGFloat = 1.1

    @MainActor
    private func formula(in textView: PageTextView?, font: NSFont) -> RenderedFormula? {
        let theme = FormulaTheme(textView?.effectiveAppearance ?? NSAppearance.currentDrawing())
        guard case .rendered(let formula) = FormulaImageCache.shared.render(latex, fontSize: font.pointSize * Self.scale, theme: theme,
                                                                            mode: .inline) else { return nil }
        return formula
    }

    @MainActor
    override func pieces(in textView: PageTextView?, font: NSFont) -> [AtomPiece] {
        switch FormulaImageCache.shared.render(latex, fontSize: font.pointSize * Self.scale, theme: .light, mode: .inline) {
        case .rendered: []
        case .empty: [.text(FormulaImageCache.emptyFormulaText, font: font, color: Palette.textSecondary)]
        case .invalid: [.text(FormulaImageCache.invalidFormulaText, font: font, color: Palette.destructiveText)]
        }
    }

    @MainActor
    override func size(in textView: PageTextView?, font: NSFont? = nil) -> CGSize {
        let font = font ?? Self.defaultFont
        guard let formula = formula(in: textView, font: font) else { return super.size(in: textView, font: font) }
        return formula.image.size
    }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        nonisolated(unsafe) let font = attributes[.font] as? NSFont ?? Self.defaultFont
        nonisolated(unsafe) let attachment = self
        nonisolated(unsafe) let container = textContainer
        return MainActor.assumeIsolated {
            let textView = container?.textView as? PageTextView
            guard let formula = attachment.formula(in: textView, font: font) else {
                let size = attachment.size(in: textView, font: font)
                return CGRect(x: 0, y: font.descender, width: size.width, height: size.height)
            }
            // Базовая линия формулы — на базовой линии текста.
            return CGRect(x: 0, y: -formula.descent, width: formula.image.size.width, height: formula.image.size.height)
        }
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                        textContainer: NSTextContainer?) -> NSImage? {
        nonisolated(unsafe) let font = attributes[.font] as? NSFont ?? Self.defaultFont
        nonisolated(unsafe) let attachment = self
        nonisolated(unsafe) let container = textContainer
        let formula = MainActor.assumeIsolated { attachment.formula(in: container?.textView as? PageTextView, font: font) }
        guard let formula else { return super.image(for: bounds, attributes: attributes, location: location, textContainer: textContainer) }
        return formula.image
    }
}
