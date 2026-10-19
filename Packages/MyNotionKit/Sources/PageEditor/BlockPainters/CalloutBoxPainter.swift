import AppKit
import NotesCore
import VisualStyle

/// Подложка выноски (contracts/blocks-and-keys.md, «Выноска»): во всю ширину блока, от первой строки выноски
/// до последнего видимого ребёнка, с полями и скруглением; без цвета фона — рамка. Каждый абзац поддерева
/// рисует свой кусок. Иконку-эмодзи рисует сама выноска.
struct CalloutBoxPainter: BlockPainter {
    var layer: BlockPaintLayer { .background }

    /// Подложка — у самой выноски и у вложенных блоков (они могут быть её детьми).
    func applies(to block: Block) -> Bool { block.kind == .callout || block.indent > 0 }

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
            let left = rect.minX + PageTextView.blockLeft(atIndent: blocks[callout].indent)
            let top = callout == index ? (context.firstLine?.top ?? rect.minY) - padding : rect.minY
            let isLast = endingHere.contains(callout)
            // Выноски, которые кончаются на этом блоке и лежат внутри этой, добавляют каждая свои поля снизу.
            let innerEnding = endingHere.filter { $0 >= callout }.count
            let bottom = isLast ? (context.lastLine.map { $0.top + $0.height } ?? rect.maxY) + padding * CGFloat(innerEnding) : rect.maxY
            let piece = CGRect(x: left, y: top, width: rect.maxX - left, height: max(0, bottom - top))
            let path = SubtreePiece.path(piece, roundsTop: callout == index, roundsBottom: isLast, radius: Metrics.Callout.cornerRadius)
            if let color = blocks[callout].color.background {
                CalloutColors.background(color).setFill()
                path.fill()
            } else {
                Self.strokeBorder(piece, roundsTop: callout == index, roundsBottom: isLast)
            }
        }
        if block.kind == .callout { Self.drawIcon(block, in: context) }
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
    static func drawIcon(_ block: Block, in context: BlockPaintContext) {
        guard let line = context.firstLine else { return }
        let iconRect = iconRect(indent: block.indent, line: line, originX: context.paragraphRect.minX)
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

/// Фон выноски по цвету Notion (contracts/blocks-and-keys.md, «Цвета»; общую палитру цветов вводит US2).
enum CalloutColors {
    static func background(_ color: NotionColor) -> NSColor {
        let (light, dark): (UInt32, UInt32) = switch color {
        case .gray: (0xF1F1EF, 0x2F2F2F)
        case .brown: (0xF4EEEE, 0x4A3228)
        case .orange: (0xFBECDD, 0x5C3B23)
        case .yellow: (0xFBF3DB, 0x564328)
        case .green: (0xEDF3EC, 0x243D30)
        case .blue: (0xE7F3F8, 0x143A4E)
        case .purple: (0xF6F3F9, 0x3C2D49)
        case .pink: (0xFAF1F5, 0x4E2C3C)
        case .red: (0xFDEBEC, 0x522E2A)
        }
        return NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }
}
