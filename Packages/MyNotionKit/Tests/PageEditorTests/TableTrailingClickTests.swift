import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Падение Юрия 27.10.2026: щелчок в ячейке таблицы пересылался в поле правки ячейки, оно считало щелчок «ниже последнего блока»
/// (блок ячейки короче самой ячейки) и добавляло пустой абзац в поток ячейки, где блок всегда один: `renderBlocks` выходил за границы.
@MainActor
@Suite("Таблица последним блоком: щелчок под ней и в ней")
struct TableTrailingClickTests {
    private func pageEndingWithTable() throws -> (editor: EditorFixture, table: UUID) {
        let editor = try EditorFixture([.paragraph("до"), .paragraph()])
        editor.placeCaret(inBlock: 1)
        editor.type("/табл")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        let table = try #require(editor.document.blocks.first { $0.kind == .table }).id
        // Последним блоком остаётся таблица: пустой абзац под ней убираем.
        if let last = editor.document.blocks.indices.last, editor.document.blocks[last].kind != .table {
            editor.step { editor.textView.removeBlocks(at: last..<last + 1) }
        }
        editor.layoutViewport()
        // Подготовка — не шаг проверки: ⌘Z после щелчка ниже отменил бы и её (пустой абзац от щелчка — не свой шаг).
        editor.undoManager.removeAllActions()
        #expect(editor.document.blocks.last?.kind == .table)
        return (editor, table)
    }

    @Test("Щелчок под таблицей, которая последняя, добавляет пустой абзац (без падения); ⌘Z его убирает")
    func trailingParagraphAfterTable() throws {
        let (editor, _) = try pageEndingWithTable()
        let before = editor.kinds
        editor.step { editor.textView.placeCaretInTrailingParagraph() }
        #expect(editor.kinds == before + [.paragraph])
        editor.undo()
        #expect(editor.kinds == before)
    }

    @Test("Точка внутри таблицы — не «ниже последнего блока»")
    func clickInsideTableIsNotBelow() throws {
        let (editor, table) = try pageEndingWithTable()
        let view = try #require(editor.textView.tableView(for: table))
        let inside = editor.textView.convert(NSPoint(x: view.bounds.midX, y: view.bounds.maxY - 5), from: view)
        #expect(!editor.textView.isBelowLastBlock(inside), "\(inside), таблица \(view.frame)")
        let firstRow = editor.textView.convert(NSPoint(x: view.bounds.midX, y: 5), from: view)
        #expect(!editor.textView.isBelowLastBlock(firstRow))
    }

    /// Таблица из «/», в первой ячейке набран текст: поле правки ячейки — в фокусе.
    private func cellWithText() throws -> (editor: EditorFixture, cell: TableCellEditor, table: UUID) {
        let editor = try EditorFixture([.paragraph("до"), .paragraph()])
        editor.placeCaret(inBlock: 1)
        editor.type("/табл")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        let table = try #require(editor.document.blocks.first { $0.kind == .table }).id
        editor.layoutViewport()
        let cell = try #require(editor.window.firstResponder as? TableCellEditor)
        editor.step { cell.insertText("Текст", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        return (editor, cell, table)
    }

    @Test("Поле правки ячейки не добавляет блоков: щелчок «ниже текста» в ячейке не падает и ничего не меняет")
    func cellEditorDoesNotAddBlocks() throws {
        let (editor, cell, _) = try cellWithText()
        let before = cell.document.blocks.map(\.id)
        let belowText = NSPoint(x: cell.bounds.midX, y: cell.bounds.maxY + 40)
        #expect(!cell.isBelowLastBlock(belowText))
        editor.step { cell.placeCaretInTrailingParagraph() }
        #expect(cell.document.blocks.map(\.id) == before)
    }

    @Test("renderBlocks не выходит за блоки документа: лишний диапазон отбрасывается")
    func renderBlocksIgnoresRangeBeyondBlocks() throws {
        let editor = try EditorFixture([.paragraph("раз"), .paragraph("два")])
        let count = editor.document.blocks.count
        editor.step { editor.textView.mapper.renderBlocks(count..<count + 1, replacing: NSRange(location: 0, length: 0)) }
        #expect(editor.document.blocks.count == count)
    }
}
