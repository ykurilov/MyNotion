import AppKit
import NotesCore
import VisualStyle

extension BlockKindDescriptor {
    /// Разделитель (US1): линия во всю ширину колонки в строке высотой 13; курсор на нём не стоит (вид-вложение).
    static let divider = BlockKindDescriptor(
        kind: .divider,
        menuItem: PopupMenuItem(title: "Разделитель", icon: .symbol("minus"), keywords: ["divider", "линия", "разделитель", "---"],
                                action: .setKind(.divider)),
        lineHeight: Metrics.Divider.rowHeight,
        topSpacing: Metrics.Divider.verticalSpacing,
        bottomSpacing: Metrics.Divider.verticalSpacing,
        painters: [DividerLinePainter()],
        gallerySamples: [
            BlockGallerySample(id: "structural-divider", summary: "Разделитель между абзацами и внутри переключателя",
                               blocks: [
                                   .init(.paragraph, "Абзац над разделителем"),
                                   .init(.divider),
                                   .init(.paragraph, "Абзац под разделителем"),
                                   .init(.toggle, "Переключатель"),
                                   .init(.divider, indent: 1),
                               ]),
        ],
        // Богатая страница (quickstart.md): 10 разделителей.
        richPageBlocks: (1...10).flatMap { number in [RichBlockSpec(.paragraph, "Перед разделителем \(number)"), RichBlockSpec(.divider)] }
    )
}

extension PageTextView {
    /// Перед курсором в пустом до этого абзаце ровно «--»: третий «-» делает разделитель.
    var isCaretAfterTwoDashes: Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location), position.offset == 2 else { return false }
        let block = document.blocks[position.index]
        return block.kind == .paragraph && block.text.string == "--"
    }

    /// «---» сразу после третьего «-» (contracts/blocks-and-keys.md, «Быстрые символы»): абзац становится разделителем,
    /// курсор — в новый абзац под ним.
    func convertDashesToDivider() {
        commitEdits()
        let selection = selectedRange()
        guard let position = mapper.blockPosition(at: selection.location) else { return }
        breakUndoCoalescing()
        guard replaceText(in: NSRange(location: selection.location - position.offset, length: position.offset), with: "") else { return }
        insertDivider(at: position.index)
    }

    /// «/» → «Разделитель»: пустой блок сам становится разделителем, у блока с текстом разделитель встаёт ниже;
    /// под разделителем — новый абзац с курсором. Одно действие для ⌘Z.
    func insertDivider(at index: Int) {
        commitEdits()
        let block = document.blocks[index]
        let divider = BlockDraft(id: block.text.string.isEmpty ? block.id : nil, kind: .divider, indent: block.indent)
        let paragraph = BlockDraft(id: nil, kind: .paragraph, indent: block.indent)
        let drafts = block.text.string.isEmpty ? [divider, paragraph] : [BlockDraft(block), divider, paragraph]
        changeBlocks(index..<index + 1, to: drafts, actionName: "Разделитель")
        let paragraphIndex = index + drafts.count - 1
        setSelectedRange(NSRange(location: mapper.paragraphStart(ofBlockAt: paragraphIndex), length: 0))
    }
}

/// Линия разделителя по середине его строки, от края вложенности до края колонки. Рисуется фрагментом абзаца,
/// а не видом-вложением: так она есть и в снимках окна, где виды вложений не рисуются.
struct DividerLinePainter: BlockPainter {
    var layer: BlockPaintLayer { .foreground }

    @MainActor
    func paint(_ block: Block, in context: BlockPaintContext) {
        guard let line = context.firstLine else { return }
        let rect = context.paragraphRect
        let left = rect.minX + Metrics.Page.blockHorizontalPadding + PageTextView.blockLeft(atIndent: block.indent)
            + context.textView.layoutShift(ofBlock: block.id)
        let lineWidth = Metrics.Divider.lineWidth
        Palette.dividerLine.setFill()
        NSRect(x: left, y: (line.top + (line.height - lineWidth) / 2).rounded(.down), width: rect.maxX - left, height: lineWidth).fill()
    }
}
