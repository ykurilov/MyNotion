import AppKit
import NotesCore
import VisualStyle

/// Подложка выноски (contracts/blocks-and-keys.md, «Выноска»): во всю ширину блока, от первой строки выноски
/// до последнего видимого ребёнка, с полями и скруглением; без цвета фона — рамка. Каждый абзац поддерева
/// рисует свой кусок. Иконку-эмодзи рисует сама выноска.
struct CalloutBoxPainter: BlockPainter {
    var layer: BlockPaintLayer { .background }

    /// Подложка — у выносок и блоков внутри цитат и выносок.
    @MainActor func applies(to block: Block, in textView: PageTextView) -> Bool { textView.isInsideSubtreePainting(block.id) }

    @MainActor
    func paint(_ block: Block, in context: BlockPaintContext) {
        let textView = context.textView
        let blocks = textView.document.blocks
        guard let index = textView.document.index(ofBlock: block.id) else { return }
        // Внешние — первыми: внутренняя подложка ложится поверх.
        var callouts = textView.ancestorIndices(ofBlockAt: index).filter { blocks[$0].kind == .callout }.reversed() as [Int]
        if block.kind == .callout { callouts.append(index) }
        guard !callouts.isEmpty else { return }
        let rect = context.paragraphRect
        let padding = Metrics.Callout.verticalPadding
        let endingHere = callouts.filter { textView.lastVisibleIndex(inSubtreeOf: $0) == index }
        for callout in callouts {
            // Край подложки — по краю текста блоков страницы, как у Notion.
            let left = rect.minX + Metrics.Page.blockHorizontalPadding + textView.blockLeft(ofBlockAt: callout)
            let top = callout == index ? (context.firstLine?.top ?? rect.minY) - padding : rect.minY
            let isLast = endingHere.contains(callout)
            // Выноски, которые кончаются на этом блоке и лежат внутри этой, добавляют каждая свои поля снизу.
            let innerEnding = endingHere.filter { $0 >= callout }.count
            let bottom = isLast ? (context.lastLine.map { $0.top + $0.height } ?? rect.maxY) + padding * CGFloat(innerEnding) : rect.maxY
            let piece = CGRect(x: left, y: top, width: rect.maxX - left, height: max(0, bottom - top))
            let path = SubtreePiece.path(piece, roundsTop: callout == index, roundsBottom: isLast, radius: Metrics.Callout.cornerRadius)
            if let fill = Palette.notionBackground(blocks[callout].color.background?.tone) {
                // Цвет подложки — общая палитра (Palette), как у фона блока и слова.
                fill.setFill()
                path.fill()
            } else {
                Self.strokeBorder(piece, roundsTop: callout == index, roundsBottom: isLast)
            }
        }
        if block.kind == .callout { Self.drawIcon(block, shift: textView.layoutShift(ofBlock: block.id), in: context) }
    }

    /// Выноска без цвета фона — тонкая рамка цвета border, как у Notion.
    @MainActor
    private static func strokeBorder(_ piece: CGRect, roundsTop: Bool, roundsBottom: Bool) {
        let inset = piece.insetBy(dx: 0.5, dy: 0)
        let clip = NSBezierPath(rect: piece)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        let outline = CGRect(x: inset.minX, y: roundsTop ? inset.minY + 0.5 : inset.minY - 10,
                             width: inset.width, height: inset.height + (roundsTop ? -0.5 : 10) + (roundsBottom ? -0.5 : 10))
        let path = SubtreePiece.path(outline, roundsTop: roundsTop, roundsBottom: roundsBottom, radius: Metrics.Callout.cornerRadius)
        path.lineWidth = 1
        Palette.border.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Иконка-эмодзи в квадрате слева от первой строки текста.
    @MainActor
    static func drawIcon(_ block: Block, shift: CGFloat, in context: BlockPaintContext) {
        guard let line = context.firstLine else { return }
        let iconRect = iconRect(indent: block.indent, line: line, originX: context.paragraphRect.minX + shift)
        let icon = block.props.icon ?? BlockProps.defaults(for: .callout).icon ?? "💡"
        let font = NSFont.systemFont(ofSize: Metrics.Callout.iconFontSize)
        let glyphs = CTLineCreateWithAttributedString(NSAttributedString(string: icon, attributes: [.font: font]))
        // Рисунок знака — по середине квадрата иконки, а значит и первой строки.
        let ink = CTLineGetImageBounds(glyphs, nil)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: iconRect.midX - ink.midX, y: iconRect.midY + ink.midY)
        CTLineDraw(glyphs, context)
        context.restoreGState()
    }

    /// Квадрат иконки по середине первой строки (координаты строки `line`, левый край контейнера — `originX`).
    static func iconRect(indent: Int, line: BlockLine, originX: CGFloat) -> CGRect {
        let side = Metrics.Callout.iconColumnWidth
        let x = originX + PageTextView.blockLeft(atIndent: indent) + Metrics.Callout.leadingPadding + Metrics.Page.blockHorizontalPadding
        return CGRect(x: x, y: line.top + (line.height - side) / 2, width: side, height: side)
    }
}
