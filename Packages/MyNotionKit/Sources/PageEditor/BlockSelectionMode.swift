import AppKit
import NotesCore
import VisualStyle

/// Режим выделения блоков как в Notion (contracts/editor-interactions.md, «Выделение блоков»): блоки подсвечены
/// целиком и действуют как целое. Включают щелчок по «⋮⋮», Esc при курсоре или выделенном тексте и протяжка мышью
/// с поля слева или справа от колонки. ↑↓ — соседний блок, ⇧↑↓ — расширить, Delete — удалить, ⌘C/⌘X — копировать
/// и вырезать, Enter — курсор в конец блока, Esc — снять. Обычное выделение текста режим снимает.
/// Под режимом выделен текст блоков целиком — копирование и Tab работают как с выделенным текстом.
extension PageTextView {
    /// Выделенные блоки; `nil` — обычный курсор или выделение текста.
    var selectedBlocks: Range<Int>? {
        guard let ends = blockSelectionEnds else { return nil }
        return min(ends.anchor, ends.head)..<max(ends.anchor, ends.head) + 1
    }

    var isBlockSelection: Bool { blockSelectionEnds != nil }

    func selectBlocks(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        selectBlocks(anchor: range.lowerBound, head: range.upperBound - 1)
    }

    /// Выделить блоки от `anchor` до `head`; `head` — подвижный край для ⇧↑↓ и протяжки.
    func selectBlocks(anchor: Int, head: Int) {
        let last = document.blocks.count - 1
        guard last >= 0 else { return }
        let anchor = min(max(anchor, 0), last), head = min(max(head, 0), last)
        let lower = min(anchor, head), upper = max(anchor, head)
        let start = mapper.paragraphStart(ofBlockAt: lower)
        let end = mapper.paragraphStart(ofBlockAt: upper) + (document.blocks[upper].text.string as NSString).length
        isApplyingBlockSelection = true
        blockSelectionEnds = (anchor, head)
        setSelectedRange(NSRange(location: start, length: end - start))
        isApplyingBlockSelection = false
        updateSelectionLook()
    }

    /// Снять режим блоков: курсор в конец блока `index`.
    private func leaveBlockSelection(caretAtEndOf index: Int) {
        let end = mapper.paragraphStart(ofBlockAt: index) + (document.blocks[index].text.string as NSString).length
        setSelectedRange(NSRange(location: end, length: 0))
    }

    /// Клавиши режима блоков; Esc при курсоре или выделенном тексте включает режим.
    func handleBlockSelectionCommand(_ selector: Selector) -> Bool {
        guard let ends = blockSelectionEnds, let range = selectedBlocks else {
            guard selector == #selector(NSResponder.cancelOperation(_:)), !hasMarkedText(), let blocks = selectedBlockRange() else { return false }
            selectBlocks(blocks)
            return true
        }
        let last = document.blocks.count - 1
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): leaveBlockSelection(caretAtEndOf: ends.head)
        case #selector(NSResponder.moveUp(_:)): selectBlocks(anchor: max(range.lowerBound - 1, 0), head: max(range.lowerBound - 1, 0))
        case #selector(NSResponder.moveDown(_:)): selectBlocks(anchor: min(range.upperBound, last), head: min(range.upperBound, last))
        case #selector(NSResponder.moveUpAndModifySelection(_:)): selectBlocks(anchor: ends.anchor, head: ends.head - 1)
        case #selector(NSResponder.moveDownAndModifySelection(_:)): selectBlocks(anchor: ends.anchor, head: ends.head + 1)
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
             #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteWordForward(_:)):
            removeBlocks(at: range)
        case #selector(NSResponder.insertNewline(_:)): leaveBlockSelection(caretAtEndOf: range.upperBound - 1)
        default: return false
        }
        return true
    }

    /// Действие над блоками в режиме блоков оставляет те же блоки выделенными.
    func keepingBlockSelection(_ action: () -> Void) {
        guard let ends = blockSelectionEnds else {
            action()
            return
        }
        let anchor = document.blocks[ends.anchor].id, head = document.blocks[ends.head].id
        action()
        if let anchor = document.index(ofBlock: anchor), let head = document.index(ofBlock: head) {
            selectBlocks(anchor: anchor, head: head)
        }
    }

    public override func cut(_ sender: Any?) {
        guard let range = selectedBlocks else {
            super.cut(sender)
            return
        }
        copy(sender)
        removeBlocks(at: range)
    }

    // MARK: Протяжка с поля

    /// Блок на высоте `y`; выше первого — первый, ниже последнего — последний.
    private func nearestBlockIndex(atY y: CGFloat) -> Int {
        if y < textContainerOrigin.y { return 0 }
        return blockIndex(atY: y) ?? document.blocks.count - 1
    }

    /// Нажатие на поле слева или справа от колонки, ниже шапки: отсюда протяжка выделяет блоки.
    func isMarginPoint(_ point: NSPoint) -> Bool {
        let origin = textContainerOrigin
        let width = textContainer?.size.width ?? Metrics.Page.columnWidth
        return point.y >= origin.y && (point.x < origin.x || point.x > origin.x + width)
    }

    func beginMarginDrag(at point: NSPoint) {
        closePopups()
        window?.makeFirstResponder(self)
        marginDrag = (point, false)
    }

    /// Мышь сдвинулась: выделены блоки, которых коснулась полоса от места нажатия до мыши.
    func continueMarginDrag(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (start, moved) = marginDrag else { return }
        if !moved, abs(point.y - start.y) < Metrics.BlockHandles.dragThreshold,
           abs(point.x - start.x) < Metrics.BlockHandles.dragThreshold { return }
        marginDrag = (start, true)
        autoscroll(with: event)
        selectBlocks(anchor: nearestBlockIndex(atY: start.y), head: nearestBlockIndex(atY: point.y))
    }

    /// Отпустили: без протяжки — курсор в ближайшее место текста, как щелчок рядом со строкой.
    func endMarginDrag(at point: NSPoint) {
        guard let (start, moved) = marginDrag else { return }
        marginDrag = nil
        guard !moved else { return }
        let index = characterIndexForInsertion(at: start)
        setSelectedRange(NSRange(location: min(index, max(0, (textStorage?.length ?? 1) - 1)), length: 0))
    }
}
