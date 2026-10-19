import AppKit
import NotesCore

/// Одно поле правки на таблицу (research R3): редактор страницы с одним блоком — ячейкой (`FlowDocument.Source.cell`).
/// Оформление в строке, упоминания, цвета, ⌘Z — как в тексте страницы; блоков в ячейке нет: «/», быстрые символы,
/// вложенность выключены. Tab, Enter, Esc и стрелки на краю текста ходят по ячейкам (contracts/blocks-and-keys.md).
@MainActor
final class TableCellEditor: FlowTextView {
    weak var table: TableView?

    init(flow: FlowDocument, host: PageTextView, table: TableView) {
        self.table = table
        super.init(flow: flow, host: host)
        setAccessibilityIdentifier("table-cell")
    }

    override var allowsBlockStructure: Bool { false }
    override var showsBlockHandles: Bool { false }

    /// В ячейке — только оформление текста.
    override func perform(_ command: EditorCommand) {
        switch command {
        case .toggleInline, .applyColor, .repeatLastColor: super.perform(command)
        default: break
        }
    }

    override func doCommand(by selector: Selector) {
        guard let table, !popups.isOpen, !mentionPicker.isOpen else { return super.doCommand(by: selector) }
        let selection = selectedRange()
        let end = max(0, (textStorage?.length ?? 1) - 1)
        switch selector {
        case #selector(NSResponder.insertTab(_:)): table.move(.next)
        case #selector(NSResponder.insertBacktab(_:)): table.move(.previous)
        case #selector(NSResponder.insertNewline(_:)): table.move(.enter)
        case #selector(NSResponder.cancelOperation(_:)):
            if handleMentionPickerCommand(selector) { return }
            table.escapeFromEditor()
        case #selector(NSResponder.moveUp(_:)) where selection.length == 0 && isCaretOnFirstLine: table.move(.up)
        case #selector(NSResponder.moveDown(_:)) where selection.length == 0 && isCaretOnLastLine: table.move(.down)
        case #selector(NSResponder.moveLeft(_:)) where selection.length == 0 && selection.location == 0: table.move(.left)
        case #selector(NSResponder.moveRight(_:)) where selection.length == 0 && selection.location >= end: table.move(.right)
        default: super.doCommand(by: selector)
        }
    }

    /// Вставка ячеек (текст с табуляциями или в несколько строк) — в ячейки от этой; иначе — текст в ячейку.
    override func paste(_ sender: Any?) {
        if !pasteCells(from: .general) { super.paste(sender) }
    }

    @discardableResult
    func pasteCells(from pasteboard: NSPasteboard) -> Bool {
        guard let table, let cell = table.activeCell, let string = pasteboard.string(forType: .string) else { return false }
        return table.pasteCells(string, at: cell)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { table?.editorDidResign(self) }
        return resigned
    }
}
