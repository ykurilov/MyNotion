import AppKit
import NotesCore
import VisualStyle

/// Подложка цвета блока: цвет фона из палитры во всю ширину блока, под текстом (FR-112).
struct BlockBackgroundPainter: BlockPainter {
    /// Что рисуется: прямоугольник, скругление и цвет заливки.
    struct Shape: Equatable {
        var rect: CGRect
        var cornerRadius: CGFloat
        var fill: NSColor
    }

    var layer: BlockPaintLayer { .background }

    /// Подложка блока с цветом `color` в области `rect`; без цвета фона подложки нет.
    static func shape(for color: BlockColor, in rect: CGRect) -> Shape? {
        guard let fill = Palette.notionBackground(color.background?.tone) else { return nil }
        return Shape(rect: rect, cornerRadius: Metrics.BlockBackground.cornerRadius, fill: fill)
    }

    @MainActor
    func paint(_ block: Block, in context: BlockPaintContext) {
        guard let shape = Self.shape(for: block.color, in: context.paragraphRect) else { return }
        shape.fill.setFill()
        NSBezierPath(roundedRect: shape.rect, xRadius: shape.cornerRadius, yRadius: shape.cornerRadius).fill()
    }
}
