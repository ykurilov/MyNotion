import AppKit
import NotesCore
import VisualStyle

/// Треугольник переключателя в колонке маркера (contracts/blocks-and-keys.md, «Раскрывающийся список»):
/// ▸ свёрнут, ▾ раскрыт. У раскрытого без детей под строкой — подсказка «Пусто. Нажмите, чтобы добавить блок».
struct TogglePainter: BlockPainter {
    var layer: BlockPaintLayer { .foreground }

    static let emptyHint = "Пусто. Нажмите, чтобы добавить блок"

    @MainActor
    func paint(_ block: Block, in context: BlockPaintContext) {
        guard let line = context.firstLine else { return }
        let textView = context.textView
        let isCollapsed = textView.collapsedBlockIds.contains(block.id)
        let column = line.markerColumn.offsetBy(dx: context.paragraphRect.minX, dy: 0)
        Self.triangle(in: column, baseline: line.baseline, pointingDown: !isCollapsed).fill(with: Palette.textPrimary)
        if textView.showsEmptyToggleHint(block) {
            let font = Typography.line(for: .paragraph).font
            let hintLine = BlockDecorationPainter.textLine(Self.emptyHint, font: font)
            let x = context.paragraphRect.minX + Metrics.Page.blockHorizontalPadding + PageTextView.blockLeft(atIndent: block.indent + 1)
                + line.shift
            BlockDecorationPainter.drawLine(hintLine, color: Palette.textSecondary,
                                            baselineOrigin: CGPoint(x: x, y: line.baseline + Metrics.block(.paragraph).height))
        }
    }

    /// Треугольник по середине колонки маркера и заглавных букв строки.
    @MainActor
    static func triangle(in column: CGRect, baseline: CGFloat, pointingDown: Bool) -> NSBezierPath {
        let center = CGPoint(x: column.midX, y: baseline - Typography.line(for: .listItem).font.capHeight / 2)
        let width = Metrics.Toggle.triangleWidth
        let height = Metrics.Toggle.triangleHeight
        let path = NSBezierPath()
        if pointingDown {
            path.move(to: CGPoint(x: center.x - height / 2, y: center.y - width / 2))
            path.line(to: CGPoint(x: center.x + height / 2, y: center.y - width / 2))
            path.line(to: CGPoint(x: center.x, y: center.y + width / 2))
        } else {
            path.move(to: CGPoint(x: center.x - width / 2, y: center.y - height / 2))
            path.line(to: CGPoint(x: center.x + width / 2, y: center.y))
            path.line(to: CGPoint(x: center.x - width / 2, y: center.y + height / 2))
        }
        path.close()
        return path
    }
}

extension NSBezierPath {
    fileprivate func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
