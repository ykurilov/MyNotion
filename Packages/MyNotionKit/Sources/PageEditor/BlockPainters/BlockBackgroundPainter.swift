import AppKit
import NotesCore
import VisualStyle

/// Подложка цвета блока: цвет фона из палитры во всю ширину блока и по высоте его строк (без отступов между абзацами), под текстом (FR-112).
struct BlockBackgroundPainter: BlockPainter {
    /// Что рисуется: прямоугольник, скругление и цвет заливки.
    struct Shape: Equatable {
        var rect: CGRect
        var cornerRadius: CGFloat
        var fill: NSColor
    }

    var layer: BlockPaintLayer { .background }

    /// Выноска красит свою подложку сама (`CalloutBoxPainter`, с полями и детьми): общий прямоугольник ей не нужен.
    @MainActor func applies(to block: Block, in textView: PageTextView) -> Bool { block.kind != .callout }

    /// Подложка блока с цветом `color` в области `rect`; без цвета фона подложки нет.
    static func shape(for color: BlockColor, in rect: CGRect) -> Shape? {
        guard let fill = Palette.notionBackground(color.background?.tone) else { return nil }
        return Shape(rect: rect, cornerRadius: Metrics.BlockBackground.cornerRadius, fill: fill)
    }

    @MainActor
    func paint(_ block: Block, in context: BlockPaintContext) {
        // Запас сверху и снизу не выходит за отступы абзаца: соседние подложки не наезжают друг на друга.
        let outset = CGRect(x: context.textRect.minX, y: context.textRect.minY - Metrics.BlockBackground.topOutset,
                            width: context.textRect.width,
                            height: context.textRect.height + Metrics.BlockBackground.topOutset + Metrics.BlockBackground.bottomOutset)
        guard let shape = Self.shape(for: block.color, in: outset.intersection(context.paragraphRect)) else { return }
        shape.fill.setFill()
        NSBezierPath(roundedRect: shape.rect, xRadius: shape.cornerRadius, yRadius: shape.cornerRadius).fill()
    }
}
