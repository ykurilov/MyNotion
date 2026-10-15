import AppKit
import CoreText
import NotesCore
import VisualStyle

/// Что стоит в колонке слева от текста блока. Маркеры не входят в текст (research R2): их рисует
/// `BlockLayoutFragment` поверх места, которое оставляет отступ абзаца.
enum BlockDecoration: Equatable {
    case bullet(String)
    case number(String)
    case checkbox(checked: Bool)
    case pageLink(LinkedPage?)
}

/// Строка блока на странице в координатах текстового контейнера.
struct BlockLine {
    var indent: Int
    var top: CGFloat
    var height: CGFloat
    var baseline: CGFloat

    /// Колонка маркера: от края вложенности на ширину `Metrics.BlockMarker.columnWidth`.
    var markerColumn: CGRect {
        let x = Metrics.Page.blockHorizontalPadding + CGFloat(indent) * Metrics.Page.indentPerLevel
        return CGRect(x: x, y: top, width: Metrics.BlockMarker.columnWidth, height: height)
    }

    /// Квадрат чекбокса по середине заглавных букв первой строки, как в Notion.
    var checkboxRect: CGRect {
        let size = Metrics.Checkbox.size
        let column = markerColumn
        let centerY = baseline - Typography.line(for: .listItem).font.capHeight / 2
        return CGRect(x: column.midX - size / 2, y: centerY - size / 2, width: size, height: size)
    }

    /// Начало текста блока за колонкой маркера.
    var textStart: CGFloat { markerColumn.minX + Metrics.BlockMarker.textInset }
}

/// Создаёт для каждого абзаца `BlockLayoutFragment`.
final class BlockLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    weak var textView: PageTextView?

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = BlockLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.textView = textView
        return fragment
    }
}

/// Абзац страницы: текст рисует TextKit, а маркер, номер, квадрат чекбокса или подстраницу — этот фрагмент
/// (contracts/visual-style.md, «Блоки»).
final class BlockLayoutFragment: NSTextLayoutFragment, @unchecked Sendable {
    weak var textView: PageTextView?

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        // Колонка маркера лежит левее текста, название подстраницы — правее пустой строки.
        let containerWidth = textLayoutManager?.textContainer?.size.width ?? Metrics.Page.columnWidth
        let wide = CGRect(x: -layoutFragmentFrame.minX, y: 0, width: containerWidth, height: layoutFragmentFrame.height)
        return bounds.union(wide)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        // TextKit рисует на главном потоке; фрагмент и контекст дальше этого вызова не уходят.
        nonisolated(unsafe) let fragment = self
        nonisolated(unsafe) let context = context
        MainActor.assumeIsolated { fragment.drawDecorations(at: point, in: context) }
    }

    @MainActor
    private func drawDecorations(at point: CGPoint, in context: CGContext) {
        guard let textView else { return }
        let lines = textView.decoratedLines(in: self)
        guard !lines.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let offset = CGPoint(x: point.x - layoutFragmentFrame.minX, y: point.y - layoutFragmentFrame.minY)
        for (decoration, line) in lines {
            BlockDecorationPainter.draw(decoration, line: line, offset: offset)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Рисование маркеров (contracts/visual-style.md, «Блоки»). `offset` переводит координаты контейнера в координаты рисования.
@MainActor
enum BlockDecorationPainter {
    static func draw(_ decoration: BlockDecoration, line: BlockLine, offset: CGPoint) {
        let column = line.markerColumn.offsetBy(dx: offset.x, dy: offset.y)
        let baseline = line.baseline + offset.y
        switch decoration {
        case .bullet(let marker):
            drawBullet(marker, in: column, baseline: baseline)
        case .number(let label):
            drawNumber(label, in: column, baseline: baseline)
        case .checkbox(let checked):
            drawCheckbox(in: line.checkboxRect.offsetBy(dx: offset.x, dy: offset.y), checked: checked)
        case .pageLink(let page):
            PageLinkPainter.draw(page, column: column, textStart: line.textStart + offset.x, baseline: baseline,
                                 maxX: offset.x + Metrics.Page.columnWidth)
        }
    }

    private static var textFont: NSFont { Typography.line(for: .listItem).font }

    /// `•` `◦` `▪` крупнее текста, по середине строчных букв.
    private static func drawBullet(_ marker: String, in column: CGRect, baseline: CGFloat) {
        let font = NSFont.systemFont(ofSize: textFont.pointSize * Metrics.BlockMarker.bulletScale)
        let line = textLine(marker, font: font)
        let glyph = CTLineGetImageBounds(line, nil)
        let center = CGPoint(x: column.midX, y: baseline - textFont.xHeight / 2)
        // Координаты перевёрнуты: середина рисунка знака выше его базовой линии на `glyph.midY`.
        drawLine(line, color: Palette.textPrimary, baselineOrigin: CGPoint(x: center.x - glyph.midX, y: center.y + glyph.midY))
    }

    /// Номер по центру колонки; длинный — вровень с её правым краем.
    private static func drawNumber(_ label: String, in column: CGRect, baseline: CGFloat) {
        let line = textLine(label, font: textFont)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let x = width <= column.width ? column.midX - width / 2 : column.maxX - width
        drawLine(line, color: Palette.textPrimary, baselineOrigin: CGPoint(x: x, y: baseline))
    }

    /// Строка текста, цвет которой берётся при рисовании.
    static func textLine(_ string: String, font: NSFont) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// Строка CoreText с базовой линией в точке, в перевёрнутых координатах окна текста.
    static func drawLine(_ line: CTLine, color: NSColor, baselineOrigin: CGPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = baselineOrigin
        context.setFillColor(color.cgColor)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawCheckbox(in rect: CGRect, checked: Bool) {
        let radius = Metrics.Checkbox.cornerRadius
        if checked {
            Palette.checkboxChecked.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            let check = NSBezierPath()
            check.move(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.52))
            check.line(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.70))
            check.line(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.32))
            check.lineWidth = Metrics.Checkbox.borderWidth + 0.3
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            Palette.checkboxCheckmark.setStroke()
            check.stroke()
        } else {
            let inset = Metrics.Checkbox.borderWidth / 2
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
            border.lineWidth = Metrics.Checkbox.borderWidth
            Palette.textPrimary.setStroke()
            border.stroke()
        }
    }
}

extension PageTextView {
    // MARK: Маркеры блоков

    /// Что рисует фрагмент: маркер своего блока на первой строке.
    func decoratedLines(in fragment: NSTextLayoutFragment) -> [(BlockDecoration, BlockLine)] {
        guard let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let id = paragraph.attributedString.attribute(.blockID, at: 0, effectiveRange: nil) as? UUID,
              let block = document.block(id), let decoration = decoration(for: block),
              let line = fragment.textLineFragments.first else { return [] }
        return [(decoration, blockLine(line, in: fragment, indent: block.indent))]
    }

    private func blockLine(_ line: NSTextLineFragment, in fragment: NSTextLayoutFragment, indent: Int) -> BlockLine {
        let frame = fragment.layoutFragmentFrame
        let top = frame.minY + line.typographicBounds.minY
        return BlockLine(indent: indent, top: top, height: line.typographicBounds.height, baseline: top + line.glyphOrigin.y)
    }

    func decoration(for block: Block) -> BlockDecoration? {
        switch block.kind {
        case .bulletItem: .bullet(ListMarkers.bullet(atIndent: block.indent))
        case .numberedItem: .number(ListMarkers.number(ordinal(ofBlock: block), atIndent: block.indent))
        case .checkbox: .checkbox(checked: block.isChecked)
        case .pageLink: .pageLink(block.linkedPageId.flatMap { linkedPages[$0] })
        case .paragraph, .heading1, .heading2, .heading3: nil
        }
    }

    /// Номер пункта: считаются пункты того же уровня подряд; вложенные глубже не прерывают счёт.
    func ordinal(ofBlock block: Block) -> Int {
        guard var index = document.index(ofBlock: block.id) else { return 1 }
        var ordinal = 1
        while index > 0 {
            index -= 1
            let previous = document.blocks[index]
            if previous.indent > block.indent { continue }
            guard previous.indent == block.indent, previous.kind == .numberedItem else { break }
            ordinal += 1
        }
        return ordinal
    }

    /// Строка блока с маркером в координатах контейнера: первая строка его абзаца.
    func markerLine(ofBlockAt index: Int) -> BlockLine? {
        guard let textLayoutManager, let contentStorage = textContentStorage, document.blocks.indices.contains(index),
              let location = contentStorage.location(contentStorage.documentRange.location, offsetBy: mapper.paragraphStart(ofBlockAt: index))
        else { return nil }
        textLayoutManager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = textLayoutManager.textLayoutFragment(for: location), let line = fragment.textLineFragments.first else { return nil }
        return blockLine(line, in: fragment, indent: document.blocks[index].indent)
    }

    /// Квадрат чекбокса в координатах окна текста.
    public func checkboxRect(ofBlock id: UUID) -> NSRect? {
        guard let index = document.index(ofBlock: id), document.blocks[index].kind == .checkbox,
              let line = markerLine(ofBlockAt: index) else { return nil }
        let origin = textContainerOrigin
        return line.checkboxRect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Чекбокс, квадрат которого под точкой (координаты окна текста).
    public func checkbox(at point: NSPoint) -> UUID? {
        guard let (index, line) = markerLineNear(point), document.blocks[index].kind == .checkbox else { return nil }
        let origin = textContainerOrigin
        // Квадрат ловит щелчок с запасом в колонку маркера: в 16 точек трудно попасть.
        let target = line.markerColumn.offsetBy(dx: origin.x, dy: origin.y)
        return target.contains(point) ? document.blocks[index].id : nil
    }

    /// Блок с маркером на высоте точки.
    func markerLineNear(_ point: NSPoint) -> (Int, BlockLine)? {
        guard let index = blockIndex(atY: point.y), let line = markerLine(ofBlockAt: index) else { return nil }
        let origin = textContainerOrigin
        let y = point.y - origin.y
        return (line.top...line.top + line.height).contains(y) ? (index, line) : nil
    }

    /// Блок на высоте `y` (координаты окна текста).
    func blockIndex(atY y: CGFloat) -> Int? {
        guard let textLayoutManager, let contentStorage = textContentStorage else { return nil }
        let containerY = y - textContainerOrigin.y
        guard let fragment = textLayoutManager.textLayoutFragment(for: CGPoint(x: 0, y: containerY))
            ?? textLayoutManager.textLayoutFragment(for: CGPoint(x: Metrics.Page.columnWidth / 2, y: containerY)) else {
            return nil
        }
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: fragment.rangeInElement.location)
        return mapper.blockPosition(at: offset)?.index
    }

    /// Перерисовать маркеры видимых блоков: номера и вид зависят от соседей.
    func redrawBlockDecorations() {
        guard let textLayoutManager else { return }
        let range = textLayoutManager.textViewportLayoutController.viewportRange ?? textLayoutManager.documentRange
        textLayoutManager.invalidateLayout(for: range)
        textLayoutManager.textViewportLayoutController.layoutViewport()
        needsDisplay = true
    }
}
