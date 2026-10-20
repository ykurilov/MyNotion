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
    /// Подсказка пустого заголовка, пункта или чекбокса без курсора (contracts/visual-style.md, «Пустые строки»).
    case placeholder(String, BlockTextStyle)
}

/// Строка блока на странице в координатах текстового контейнера.
struct BlockLine {
    var indent: Int
    /// Сдвиг блока вбок от его глубины (`PageTextView.layoutShift`).
    var shift: CGFloat = 0
    var top: CGFloat
    var height: CGFloat
    var baseline: CGFloat
    /// Где в пустой строке стоит курсор: начало текста блока.
    var caretX: CGFloat = 0

    /// Колонка маркера: от края вложенности на ширину `Metrics.BlockMarker.columnWidth`.
    var markerColumn: CGRect {
        let x = Metrics.Page.blockHorizontalPadding + CGFloat(indent) * Metrics.Page.indentPerLevel + shift
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
        // Сверху — место поля выноски: у первого блока страницы TextKit не даёт отступа над абзацем.
        let wide = CGRect(x: -layoutFragmentFrame.minX, y: -Metrics.Callout.verticalPadding, width: containerWidth,
                          height: layoutFragmentFrame.height + Metrics.Callout.verticalPadding)
        return bounds.union(wide)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // TextKit рисует на главном потоке; фрагмент и контекст дальше этого вызова не уходят.
        nonisolated(unsafe) let fragment = self
        nonisolated(unsafe) let context = context
        MainActor.assumeIsolated { fragment.paint(.background, at: point, in: context) }
        super.draw(at: point, in: context)
        MainActor.assumeIsolated {
            fragment.drawDecorations(at: point, in: context)
            fragment.paint(.foreground, at: point, in: context)
        }
    }

    /// Рисователи блока этого абзаца (`BlockPainters`): подложка под текстом, черта и значки поверх.
    @MainActor
    private func paint(_ layer: BlockPaintLayer, at point: CGPoint, in context: CGContext) {
        guard let textView, let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let id = paragraph.attributedString.attribute(.blockID, at: 0, effectiveRange: nil) as? UUID,
              let block = textView.document.block(id) else { return }
        let painters = BlockPainters.painters(for: block.kind).filter { $0.layer == layer && $0.applies(to: block, in: textView) }
        guard !painters.isEmpty else { return }
        let offset = CGPoint(x: point.x - layoutFragmentFrame.minX, y: point.y - layoutFragmentFrame.minY)
        let width = textLayoutManager?.textContainer?.size.width ?? Metrics.Page.columnWidth
        let rect = CGRect(x: offset.x, y: point.y, width: width, height: layoutFragmentFrame.height)
        func blockLine(_ line: NSTextLineFragment) -> BlockLine {
            let top = layoutFragmentFrame.minY + line.typographicBounds.minY + offset.y
            return BlockLine(indent: block.indent, shift: textView.layoutShift(ofBlock: block.id), top: top,
                             height: line.typographicBounds.height, baseline: top + line.glyphOrigin.y)
        }
        // Пустая строка после последнего перевода строки страницы к тексту блока не относится.
        let lines = textLineFragments.filter { $0.characterRange.length > 0 }
        let linesTop = lines.map(\.typographicBounds.minY).min() ?? 0
        let linesBottom = lines.map(\.typographicBounds.maxY).max() ?? layoutFragmentFrame.height
        let textRect = CGRect(x: rect.minX, y: point.y + linesTop, width: width, height: max(0, linesBottom - linesTop))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let paintContext = BlockPaintContext(paragraphRect: rect, textRect: textRect,
                                             firstLine: (lines.first ?? textLineFragments.first).map(blockLine),
                                             lastLine: (lines.last ?? textLineFragments.first).map(blockLine), textView: textView)
        for painter in painters { painter.paint(block, in: paintContext) }
        NSGraphicsContext.restoreGraphicsState()
    }

    @MainActor
    private func drawDecorations(at point: CGPoint, in context: CGContext) {
        guard let textView else { return }
        let lines = textView.decoratedLines(in: self)
        guard !lines.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let offset = CGPoint(x: point.x - layoutFragmentFrame.minX, y: point.y - layoutFragmentFrame.minY)
        let scale = textView.layoutSettings.fontScale
        for (decoration, line) in lines {
            // Мелкий шрифт: маркер, номер, чекбокс и подсказка — той же шкалой, что текст, у своей строки.
            let anchor: CGPoint? = switch decoration {
            case .pageLink: nil
            case .placeholder: CGPoint(x: line.caretX + offset.x, y: line.baseline + offset.y)
            default: CGPoint(x: line.markerColumn.midX + offset.x, y: line.baseline + offset.y)
            }
            guard scale != 1, let anchor else {
                BlockDecorationPainter.draw(decoration, line: line, offset: offset)
                continue
            }
            context.saveGState()
            context.translateBy(x: anchor.x, y: anchor.y)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -anchor.x, y: -anchor.y)
            BlockDecorationPainter.draw(decoration, line: line, offset: offset)
            context.restoreGState()
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
        case .placeholder(let hint, let style):
            // С начала текста блока, как подсказка под курсором (`PageTextView.updateEmptyParagraphHint`).
            let x = line.caretX + offset.x
            drawLine(textLine(hint, font: Typography.line(for: style).font), color: Palette.textSecondary,
                     baselineOrigin: CGPoint(x: x, y: baseline))
        }
    }

    private static var textFont: NSFont { Typography.line(for: .listItem).font }

    /// Шрифт знака маркера: у `•` и `▪` один видимый размер.
    static func bulletFont(for marker: String) -> NSFont {
        let scale = marker == "▪" ? Metrics.BlockMarker.squareBulletScale : Metrics.BlockMarker.bulletScale
        return NSFont.systemFont(ofSize: textFont.pointSize * scale)
    }

    /// Видимый размер маркера: `◦` — кольцо размером с `•`.
    static func bulletSize(for marker: String) -> CGSize {
        let glyph = marker == "◦" ? "•" : marker
        return CTLineGetImageBounds(textLine(glyph, font: bulletFont(for: glyph)), nil).size
    }

    /// `•` `◦` `▪` крупнее текста, по середине строчных букв.
    private static func drawBullet(_ marker: String, in column: CGRect, baseline: CGFloat) {
        let center = CGPoint(x: column.midX, y: baseline - textFont.xHeight / 2)
        if marker == "◦" {
            let size = bulletSize(for: marker)
            let lineWidth = Metrics.BlockMarker.hollowBulletLineWidth
            let ring = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            let path = NSBezierPath(ovalIn: ring.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
            path.lineWidth = lineWidth
            Palette.textPrimary.setStroke()
            path.stroke()
            return
        }
        let line = textLine(marker, font: bulletFont(for: marker))
        let glyph = CTLineGetImageBounds(line, nil)
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

    /// Что рисует фрагмент на первой строке своего блока: маркер и подсказку пустого блока без курсора.
    func decoratedLines(in fragment: NSTextLayoutFragment) -> [(BlockDecoration, BlockLine)] {
        guard let paragraph = fragment.textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let id = paragraph.attributedString.attribute(.blockID, at: 0, effectiveRange: nil) as? UUID,
              let block = document.block(id), let first = fragment.textLineFragments.first else { return [] }
        let line = blockLine(first, in: fragment, block: block)
        var lines: [(BlockDecoration, BlockLine)] = []
        if let decoration = decoration(for: block) { lines.append((decoration, line)) }
        let isEmpty = paragraph.attributedString.string.trimmingCharacters(in: .newlines).isEmpty
        if isEmpty, block.id != emptyHintBlockID, let placeholder = Self.persistentPlaceholder(for: block.kind) {
            lines.append((.placeholder(placeholder, PageTextStorageMapper.textStyle(of: block.kind)), line))
        }
        return lines
    }

    /// Подсказка, видная и без курсора: у заголовков, пунктов и чекбоксов, как в Notion. У абзаца — только под курсором.
    static func persistentPlaceholder(for kind: BlockKind) -> String? {
        kind == .paragraph ? nil : emptyBlockHint(for: kind)
    }

    private func blockLine(_ line: NSTextLineFragment, in fragment: NSTextLayoutFragment, block: Block) -> BlockLine {
        let frame = fragment.layoutFragmentFrame
        let top = frame.minY + line.typographicBounds.minY
        let caretX = frame.minX + line.typographicBounds.minX + line.locationForCharacter(at: 0).x
        return BlockLine(indent: block.indent, shift: layoutShift(ofBlock: block.id), top: top, height: line.typographicBounds.height,
                         baseline: top + line.glyphOrigin.y, caretX: caretX)
    }

    /// Маркер в колонке слева — по описателю типа (`BlockKinds/`).
    func decoration(for block: Block) -> BlockDecoration? {
        switch block.kind.descriptor.marker {
        case .bullet: .bullet(ListMarkers.bullet(atIndent: block.indent))
        case .number: .number(ListMarkers.number(ordinal(ofBlock: block), atIndent: block.indent))
        case .checkbox: .checkbox(checked: block.isChecked)
        case .pageLink: .pageLink(block.linkedPageId.flatMap { linkedPages[$0] })
        case .none, .painted: nil
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
        return blockLine(line, in: fragment, block: document.blocks[index])
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

    /// Перерисовать строки блоков без пересчёта раскладки: подсказка без курсора появилась или пропала.
    /// Пересчёт раскладки здесь не нужен и сдвигает строки ниже на время до следующей раскладки.
    func redrawBlocks(_ ids: [UUID]) {
        guard let textLayoutManager, let contentStorage = textContentStorage else { return }
        let length = textStorage?.length ?? 0
        for id in ids {
            guard let index = document.index(ofBlock: id) else { continue }
            let start = mapper.paragraphStart(ofBlockAt: index)
            let end = index + 1 < document.blocks.count ? mapper.paragraphStart(ofBlockAt: index + 1) : length
            guard let from = contentStorage.location(contentStorage.documentRange.location, offsetBy: start),
                  let to = contentStorage.location(from, offsetBy: max(0, end - start)),
                  let range = NSTextRange(location: from, end: to) else { continue }
            textLayoutManager.invalidateRenderingAttributes(for: range)
        }
        needsDisplay = true
    }

    /// Перерисовать маркеры видимых блоков: номера и вид зависят от соседей.
    func redrawBlockDecorations() {
        // Вне окна рисовать нечего, а без видимой области перекладывался бы весь документ: страница только
        // создаётся, и в окне её всё равно разложат заново.
        guard window != nil, let textLayoutManager else { return }
        let range = textLayoutManager.textViewportLayoutController.viewportRange ?? textLayoutManager.documentRange
        textLayoutManager.invalidateLayout(for: range)
        textLayoutManager.textViewportLayoutController.layoutViewport()
        needsDisplay = true
    }
}
