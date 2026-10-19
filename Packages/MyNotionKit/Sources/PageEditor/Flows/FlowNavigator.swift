import AppKit
import NotesCore

/// Курсор между редакторами страницы (contracts/blocks-and-keys.md, «Колонки»; research R3): ↑ с первой строки колонки —
/// в блок над колонками, ↓ с последней — в блок под ними, → в конце колонки — в начало следующей, ← в начале —
/// в конец предыдущей; ↓ со строки над колонками — в первую колонку, ↑ со строки под ними — в неё же.
@MainActor
enum FlowNavigator {
    enum Direction { case up, down, left, right }

    /// Перевести курсор в соседний редактор; `false` — движение остаётся внутри этого редактора.
    static func move(_ direction: Direction, from editor: PageTextView) -> Bool {
        let selection = editor.selectedRange()
        guard selection.length == 0, !editor.hasMarkedText(), !editor.isBlockSelection, !editor.popups.isOpen else { return false }
        if let column = editor as? FlowTextView, case .container = column.document.source, moveOut(direction, from: column) { return true }
        return moveIn(direction, from: editor)
    }

    // MARK: Из колонки

    private static func moveOut(_ direction: Direction, from column: FlowTextView) -> Bool {
        guard let host = column.host, let columnId = column.document.containerId,
              let listId = column.document.pageDocument.block(columnId)?.containerId,
              let listIndex = host.document.index(ofBlock: listId) else { return false }
        let siblings = host.flowEditors(inColumnList: listId)
        let position = siblings.firstIndex { $0 === column }
        let location = column.selectedRange().location
        let end = max(0, (column.textStorage?.length ?? 1) - 1)
        switch direction {
        case .up:
            guard column.isCaretOnFirstLine else { return false }
            return focusEnd(ofBlockAt: listIndex - 1, in: host)
        case .down:
            guard column.isCaretOnLastLine else { return false }
            return focusStart(ofBlockAt: listIndex + 1, in: host)
        case .right:
            guard location >= end else { return false }
            if let position, position + 1 < siblings.count {
                siblings[position + 1].focus(atEnd: false)
                return true
            }
            return focusStart(ofBlockAt: listIndex + 1, in: host)
        case .left:
            guard location == 0 else { return false }
            if let position, position > 0 {
                siblings[position - 1].focus(atEnd: true)
                return true
            }
            return focusEnd(ofBlockAt: listIndex - 1, in: host)
        }
    }

    // MARK: В колонки

    /// ↓ на последней строке блока прямо над колонками и ↑ на первой строке блока прямо под ними — в первую колонку.
    private static func moveIn(_ direction: Direction, from editor: PageTextView) -> Bool {
        guard direction == .up || direction == .down,
              let position = editor.mapper.blockPosition(at: editor.selectedRange().location) else { return false }
        let neighbour = position.index + (direction == .down ? 1 : -1)
        guard editor.document.blocks.indices.contains(neighbour) else { return false }
        let block = editor.document.blocks[neighbour]
        guard block.kind == .columnList, direction == .down ? editor.isCaretOnLastLineOfBlock : editor.isCaretOnFirstLineOfBlock,
              let first = editor.flowEditors(inColumnList: block.id).first else { return false }
        first.focus(atEnd: direction == .up)
        return true
    }

    private static func focusStart(ofBlockAt index: Int, in editor: PageTextView) -> Bool {
        guard editor.document.blocks.indices.contains(index) else { return false }
        editor.window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: editor.mapper.paragraphStart(ofBlockAt: index), length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        return true
    }

    private static func focusEnd(ofBlockAt index: Int, in editor: PageTextView) -> Bool {
        guard editor.document.blocks.indices.contains(index) else { return false }
        editor.window?.makeFirstResponder(editor)
        let location = editor.mapper.paragraphStart(ofBlockAt: index) + editor.document.blocks[index].pageTextLength
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        return true
    }
}

extension PageTextView {
    public override func moveUp(_ sender: Any?) {
        if FlowNavigator.move(.up, from: self) { return }
        super.moveUp(sender)
    }

    public override func moveDown(_ sender: Any?) {
        if FlowNavigator.move(.down, from: self) { return }
        super.moveDown(sender)
    }

    public override func moveLeft(_ sender: Any?) {
        if FlowNavigator.move(.left, from: self) { return }
        super.moveLeft(sender)
    }

    public override func moveRight(_ sender: Any?) {
        if FlowNavigator.move(.right, from: self) { return }
        super.moveRight(sender)
    }

    // MARK: Строка курсора

    /// Строка курсора внутри его блока: номер строки и сколько их.
    private var caretLine: (block: Int, line: Int, count: Int)? {
        let location = selectedRange().location
        guard let textLayoutManager, let storage = textContentStorage, let position = mapper.blockPosition(at: location),
              let textLocation = storage.location(storage.documentRange.location, offsetBy: mapper.paragraphStart(ofBlockAt: position.index))
        else { return nil }
        textLayoutManager.ensureLayout(for: NSTextRange(location: textLocation))
        guard let fragment = textLayoutManager.textLayoutFragment(for: textLocation) else { return nil }
        let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
        guard !lines.isEmpty else { return (position.index, 0, 1) }
        let offset = position.offset
        let line = lines.firstIndex { offset < $0.characterRange.upperBound } ?? lines.count - 1
        return (position.index, line, lines.count)
    }

    var isCaretOnFirstLineOfBlock: Bool { caretLine.map { $0.line == 0 } ?? false }
    var isCaretOnLastLineOfBlock: Bool { caretLine.map { $0.line == $0.count - 1 } ?? false }

    /// Курсор на первой строке текста редактора.
    var isCaretOnFirstLine: Bool { caretLine.map { $0.block == 0 && $0.line == 0 } ?? true }
    /// Курсор на последней строке текста редактора.
    var isCaretOnLastLine: Bool {
        caretLine.map { $0.block == document.blocks.count - 1 && $0.line == $0.count - 1 } ?? true
    }
}
