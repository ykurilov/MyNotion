import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Два режима выделения, как в Notion 7.38.1 (проверено в виртуальном Mac 15.10.2026). Выделение текста — мышью
/// по тексту или Shift+стрелками — всегда полосы по тексту, даже через блоки. Режим выделения блоков включают
/// щелчок по «⋮⋮», Esc при курсоре или выделенном тексте и протяжка мышью с поля слева или справа от колонки.
/// В режиме блоков: ↑↓ переносят выделение на соседний блок, ⇧↑↓ расширяют, Delete удаляет блоки, ⌘C копирует,
/// набор букв ничего не меняет, Esc снимает выделение; щелчок в текст возвращает обычный курсор.
@MainActor
@Suite("Режим выделения блоков как в Notion")
struct BlockSelectionModeTests {
    private func makeEditor() throws -> EditorFixture {
        try EditorFixture([.paragraph("раз"), .bullet("два"), .paragraph("три"), .numbered("четыре"), .paragraph("пять")])
    }

    private let escape = #selector(NSResponder.cancelOperation(_:))

    @Test("Shift+стрелки и мышь по тексту через блоки — выделение текста, не блоков")
    func textSelectionAcrossBlocksIsText() throws {
        let editor = try makeEditor()
        editor.placeCaret(inBlock: 0, at: 1)
        for _ in 0..<5 { editor.press(#selector(NSResponder.moveRightAndModifySelection(_:))) }
        #expect(editor.textView.selectedBlockRange() == 0..<2)
        #expect(!editor.textView.isBlockSelection)
        #expect(editor.textView.selectedBlocks == nil)
    }

    @Test("Esc при курсоре выделяет его блок; при выделении текста через блоки — эти блоки; курсора нет")
    func escapeSelectsBlocks() throws {
        let editor = try makeEditor()
        editor.textView.caret.showsWithoutKeyWindow = true
        editor.placeCaret(inBlock: 1, at: 1)
        editor.press(escape)
        #expect(editor.textView.selectedBlocks == 1..<2)
        #expect(editor.textView.isBlockSelection)
        #expect(!editor.textView.caret.isShown, "В режиме блоков виден курсор")
        #expect(editor.textView.selectionHighlightRects().count == 1)

        editor.placeCaret(inBlock: 2, at: 1)
        editor.textView.setSelectedRange(NSRange(location: editor.textLocation(ofBlock: 2) + 1, length: editor.textLocation(ofBlock: 3) + 2 - editor.textLocation(ofBlock: 2) - 1))
        editor.press(escape)
        #expect(editor.textView.selectedBlocks == 2..<4)
        #expect(editor.textView.selectionHighlightRects().count == 2)
    }

    @Test("↑↓ переносят выделение на соседний блок, ⇧↑↓ расширяют и сужают, Esc снимает")
    func arrowsMoveAndExtend() throws {
        let editor = try makeEditor()
        let textView = editor.textView
        editor.placeCaret(inBlock: 1)
        editor.press(escape)
        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(textView.selectedBlocks == 2..<3)
        editor.press(#selector(NSResponder.moveUp(_:)))
        editor.press(#selector(NSResponder.moveUp(_:)))
        #expect(textView.selectedBlocks == 0..<1)
        editor.press(#selector(NSResponder.moveUp(_:)))
        #expect(textView.selectedBlocks == 0..<1, "Выше первого блока выделение не уходит")
        editor.press(#selector(NSResponder.moveDownAndModifySelection(_:)))
        editor.press(#selector(NSResponder.moveDownAndModifySelection(_:)))
        #expect(textView.selectedBlocks == 0..<3)
        editor.press(#selector(NSResponder.moveUpAndModifySelection(_:)))
        #expect(textView.selectedBlocks == 0..<2)
        editor.press(#selector(NSResponder.moveDown(_:)))
        #expect(textView.selectedBlocks == 2..<3, "↓ после нескольких блоков — блок под ними")
        editor.press(escape)
        #expect(textView.selectedBlocks == nil)
        #expect(!textView.isBlockSelection)
        #expect(textView.selectionHighlightRects().isEmpty)
        #expect(editor.texts == ["раз", "два", "три", "четыре", "пять"])
    }

    @Test("Delete удаляет выделенные блоки целиком одним шагом отмены")
    func deleteRemovesBlocks() throws {
        let editor = try makeEditor()
        editor.textView.selectBlocks(1..<3)
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.texts == ["раз", "четыре", "пять"])
        #expect(editor.kinds == [.paragraph, .numberedItem, .paragraph])
        #expect(editor.textView.selectedBlocks == nil)
        editor.undo()
        #expect(editor.texts == ["раз", "два", "три", "четыре", "пять"])
        #expect(editor.kinds == [.paragraph, .bulletItem, .paragraph, .numberedItem, .paragraph])

        editor.textView.selectBlocks(4..<5)
        editor.press(#selector(NSResponder.deleteForward(_:)))
        #expect(editor.texts == ["раз", "два", "три", "четыре"])
    }

    @Test("⌘C копирует текст выделенных блоков целиком, по строке на блок")
    func copyTakesWholeBlocks() throws {
        let editor = try makeEditor()
        editor.textView.selectBlocks(1..<4)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MyNotionTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(editor.textView.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "два\nтри\nчетыре")
    }

    @Test("Набор букв в режиме блоков текст не меняет; Enter — курсор в конец блока")
    func typingDoesNotReplaceBlocks() throws {
        let editor = try makeEditor()
        editor.textView.selectBlocks(1..<3)
        editor.type("ж")
        #expect(editor.texts == ["раз", "два", "три", "четыре", "пять"])
        #expect(editor.textView.selectedBlocks == 1..<3)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(editor.textView.selectedBlocks == nil)
        #expect(editor.document.blocks.count == 5)
        #expect(editor.textView.selectedRange() == NSRange(location: editor.textLocation(ofBlock: 2) + 3, length: 0))
    }

    @Test("Пустой блок тоже выделяется подложкой")
    func emptyBlockSelected() throws {
        let editor = try EditorFixture([.paragraph("раз"), .paragraph(""), .paragraph("три")])
        editor.textView.caret.showsWithoutKeyWindow = true
        editor.placeCaret(inBlock: 1)
        #expect(editor.textView.caret.isShown)
        editor.press(escape)
        #expect(editor.textView.selectedBlocks == 1..<2)
        let rects = editor.textView.selectionHighlightRects()
        try #require(rects.count == 1)
        #expect(rects[0].height >= 24 + 6 - 0.5, "Подложка пустого блока \(rects[0])")
        #expect(!editor.textView.caret.isShown, "В выделенном пустом блоке виден курсор")
    }

    @Test("Щелчок в текст выходит из режима блоков")
    func caretLeavesBlockMode() throws {
        let editor = try makeEditor()
        editor.textView.selectBlocks(0..<2)
        editor.placeCaret(inBlock: 3, at: 2)
        #expect(editor.textView.selectedBlocks == nil)
        #expect(editor.textView.selectionHighlightRects().isEmpty)
    }

    @Test("Tab в режиме блоков вкладывает пункты, и блоки остаются выделенными")
    func indentKeepsBlockMode() throws {
        let editor = try EditorFixture([.bullet("раз"), .bullet("два"), .bullet("три")])
        editor.textView.selectBlocks(1..<3)
        editor.press(#selector(NSResponder.insertTab(_:)))
        #expect(editor.indents == [0, 1, 1])
        #expect(editor.textView.selectedBlocks == 1..<3)
    }

    // MARK: Мышь

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in editor: EditorFixture) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: editor.textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                        windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Середина первой строки блока по высоте (координаты окна текста).
    private func lineMidY(ofBlock index: Int, in editor: EditorFixture) throws -> CGFloat {
        let line = try #require(editor.textView.markerLine(ofBlockAt: index))
        return editor.textView.textContainerOrigin.y + line.top + line.height / 2
    }

    @Test("Щелчок по «⋮⋮» выделяет блок и открывает меню блока; Esc закрывает меню, блок остаётся выделен")
    func gripClickSelectsBlock() throws {
        let editor = try makeEditor()
        editor.placeCaret(inBlock: 0)
        let textView = editor.textView
        textView.blockHandles.show(forBlockAt: 2, line: try #require(textView.markerLine(ofBlockAt: 2)))
        let handle = textView.blockHandles.dragHandle
        let grip = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: textView)
        handle.mouseDown(with: try mouse(.leftMouseDown, at: grip, in: editor))
        editor.step { handle.mouseUp(with: try! mouse(.leftMouseUp, at: grip, in: editor)) }
        #expect(textView.selectedBlocks == 2..<3)
        #expect(textView.popups.isOpen, "Меню блока не открылось")
        editor.press(escape)
        #expect(!textView.popups.isOpen)
        #expect(textView.selectedBlocks == 2..<3, "Esc в меню снял и выделение блока")
        editor.press(escape)
        #expect(textView.selectedBlocks == nil)
    }

    @Test("Протяжка мышью с поля слева выделяет блоки, которых коснулась; с поля справа — тоже")
    func marginDragSelectsBlocks() throws {
        let editor = try makeEditor()
        editor.placeCaret(inBlock: 0)
        let textView = editor.textView
        let origin = textView.textContainerOrigin
        let left = origin.x - Metrics.BlockHandles.addButtonLeadingOffset - 20
        try #require(left > 0, "Нет поля слева: \(origin)")
        textView.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: left, y: try lineMidY(ofBlock: 1, in: editor)), in: editor))
        textView.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: left + 40, y: try lineMidY(ofBlock: 3, in: editor)), in: editor))
        #expect(textView.selectedBlocks == 1..<4, "Во время протяжки")
        textView.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: left + 60, y: try lineMidY(ofBlock: 2, in: editor)), in: editor))
        #expect(textView.selectedBlocks == 1..<3, "Протяжка назад сужает выделение")
        textView.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: left + 60, y: try lineMidY(ofBlock: 2, in: editor)), in: editor))
        #expect(textView.selectedBlocks == 1..<3)
        #expect(editor.texts == ["раз", "два", "три", "четыре", "пять"])

        let right = origin.x + Metrics.Page.columnWidth + 20
        try #require(right < textView.bounds.width, "Нет поля справа")
        textView.mouseDown(with: try mouse(.leftMouseDown, at: NSPoint(x: right, y: try lineMidY(ofBlock: 4, in: editor)), in: editor))
        textView.mouseDragged(with: try mouse(.leftMouseDragged, at: NSPoint(x: right - 100, y: try lineMidY(ofBlock: 3, in: editor)), in: editor))
        textView.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: right - 100, y: try lineMidY(ofBlock: 3, in: editor)), in: editor))
        #expect(textView.selectedBlocks == 3..<5)
    }
}
