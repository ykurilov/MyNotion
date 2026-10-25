import AppKit
import CoreText
import NotesCore
import VisualStyle

/// Свёрнутый заголовок (toggle heading Notion): его раздел прячется, как дети переключателя (`CollapsedParagraphs`);
/// слева, в месте «+» ручек, всегда видна стрелка ▸, справа от текста — серая подпись «…N блоков». Щелчок по стрелке
/// или подписи разворачивает, по тексту — обычная правка.
struct HeadingFoldPainter: BlockPainter {
    var layer: BlockPaintLayer { .foreground }

    @MainActor
    func applies(to block: Block, in textView: PageTextView) -> Bool {
        textView.collapsedBlockIds.contains(block.id)
    }

    @MainActor
    func paint(_ block: Block, in context: BlockPaintContext) {
        guard let first = context.firstLine else { return }
        let textView = context.textView
        let center = Self.arrowCenter(columnLeft: context.paragraphRect.minX, baseline: first.baseline, kind: block.kind)
        TogglePainter.triangle(center: center, pointingDown: false).fill(with: Self.arrowColor)
        guard let label = textView.foldedLabel(ofBlock: block.id), let last = context.lastLine else { return }
        let font = Self.labelFont(scale: textView.layoutSettings.fontScale)
        BlockDecorationPainter.drawLine(BlockDecorationPainter.textLine(label, font: font), color: Palette.textSecondary,
                                        baselineOrigin: CGPoint(x: last.textEnd + Metrics.HeadingFold.labelSpacing, y: last.baseline))
    }

    /// Цвет стрелки — как у треугольника переключателя.
    static var arrowColor: NSColor { Palette.textPrimary }

    /// Середина стрелки: середина кнопки «+» ручек по высоте строчных букв первой строки (`BlockHandlesOverlay.show`).
    @MainActor
    static func arrowCenter(columnLeft: CGFloat, baseline: CGFloat, kind: BlockKind) -> CGPoint {
        let font = Typography.line(for: PageTextStorageMapper.textStyle(of: kind)).font
        return CGPoint(x: columnLeft - Metrics.BlockHandles.addButtonLeadingOffset + Metrics.BlockHandles.addButtonSize.width / 2,
                       y: baseline - font.xHeight / 2)
    }

    @MainActor
    static func labelFont(scale: CGFloat) -> NSFont {
        let font = Typography.line(for: .paragraph).font
        return scale == 1 ? font : font.withSize(font.pointSize * scale)
    }
}

extension NSBezierPath {
    fileprivate func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

extension PageTextView {
    // MARK: Свёрнутый заголовок

    /// «…N блоков» у свёрнутого заголовка, которому есть что прятать; иначе `nil`.
    public func foldedLabel(ofBlock id: UUID) -> String? {
        guard collapsedBlockIds.contains(id), let index = document.index(ofBlock: id), document.blocks[index].kind.isHeading else { return nil }
        let count = HeadingSections.foldedCount(document.blocks, ofHeadingAt: index)
        return count > 0 ? HeadingSections.foldedLabel(count: count) : nil
    }

    /// Рамка подписи «…N блоков» в координатах окна текста.
    public func foldedLabelRect(ofBlock id: UUID) -> NSRect? {
        guard let label = foldedLabel(ofBlock: id), let index = document.index(ofBlock: id),
              let line = lastTextLine(ofBlockAt: index) else { return nil }
        let textLine = BlockDecorationPainter.textLine(label, font: HeadingFoldPainter.labelFont(scale: layoutSettings.fontScale))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(textLine, &ascent, &descent, nil)
        let origin = textContainerOrigin
        return NSRect(x: origin.x + line.textEnd + Metrics.HeadingFold.labelSpacing, y: origin.y + line.baseline - ascent,
                      width: width, height: ascent + descent)
    }

    /// Свёрнутый заголовок, чья подпись под точкой (координаты окна текста).
    func foldedLabel(at point: NSPoint) -> UUID? {
        guard !collapsedBlockIds.isEmpty, let index = blockIndex(atY: point.y) else { return nil }
        let id = document.blocks[index].id
        // Запас по краям: в подпись мелким шрифтом трудно попасть.
        return foldedLabelRect(ofBlock: id)?.insetBy(dx: -4, dy: -4).contains(point) == true ? id : nil
    }

    /// Конец блоков, которые едут вместе с блоком `index` при перестановке: у свёрнутого заголовка — с его разделом,
    /// у остальных — с вложенными.
    func movedGroupEnd(ofBlockAt index: Int) -> Int {
        let blocks = document.blocks
        if blocks[index].kind.isHeading, collapsedBlockIds.contains(blocks[index].id) {
            return HeadingSections.sectionEnd(blocks, ofHeadingAt: index)
        }
        return BlockMoveController.subtreeEnd(blocks, of: index)
    }
}
