import AppKit
import NotesCore
import VisualStyle

/// Черта цитаты (contracts/blocks-and-keys.md, «Цитата»): 3 точки цвета текста слева, от первой строки цитаты
/// до последней строки последнего видимого ребёнка. Каждый абзац поддерева рисует свой кусок, куски смыкаются.
struct QuoteBarPainter: BlockPainter {
    var layer: BlockPaintLayer { .background }

    /// Черта — у самой цитаты и у вложенных блоков (они могут быть её детьми).
    func applies(to block: Block) -> Bool { block.kind == .quote || block.indent > 0 }

    @MainActor
    func paint(_ block: Block, in context: BlockPaintContext) {
        let textView = context.textView
        guard let index = textView.document.index(ofBlock: block.id) else { return }
        var quotes = textView.ancestorIndices(ofBlockAt: index).filter { textView.document.blocks[$0].kind == .quote }
        if block.kind == .quote { quotes.insert(index, at: 0) }
        guard !quotes.isEmpty else { return }
        let rect = context.paragraphRect
        Palette.textPrimary.setFill()
        for quote in quotes {
            let top = quote == index ? context.firstLine?.top ?? rect.minY : rect.minY
            let isLast = textView.lastVisibleIndex(inSubtreeOf: quote) == index
            let bottom = isLast ? context.lastLine.map { $0.top + $0.height } ?? rect.maxY : rect.maxY
            let x = rect.minX + Metrics.Page.blockHorizontalPadding
                + PageTextView.blockLeft(atIndent: textView.document.blocks[quote].indent)
            NSRect(x: x, y: top, width: Metrics.Quote.barWidth, height: max(0, bottom - top)).fill()
        }
    }
}
