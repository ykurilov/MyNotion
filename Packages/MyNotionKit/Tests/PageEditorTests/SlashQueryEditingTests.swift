import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Запрос после «/» правится внутри, как в Notion: меню открыто, пока курсор в запросе.
@MainActor
@Suite("Меню «/»: правка запроса внутри")
struct SlashQueryEditingTests {
    private func openMenu(typing text: String) throws -> EditorFixture {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)
        editor.type(text)
        #expect(editor.textView.popups.isOpen)
        return editor
    }

    private func moveLeft(_ editor: EditorFixture, _ count: Int) {
        for _ in 0..<count { editor.press(#selector(NSResponder.moveLeft(_:))) }
    }

    private func expectItemsMatch(_ query: String, in editor: EditorFixture) {
        #expect(editor.textView.popups.visibleItems == PopupMenuItem.slashItems(matching: query), "запрос «\(query)»")
    }

    @Test("Стрелки влево и вправо по запросу не закрывают меню, подсветка остаётся на всём запросе")
    func arrowsInsideQuery() throws {
        let editor = try openMenu(typing: "/загол")
        moveLeft(editor, 3)
        #expect(editor.textView.popups.isOpen)
        let highlight = try #require(editor.textView.slashQueryHighlightFrame)
        let whole = editor.textView.firstRect(forCharacterRange: NSRange(location: 0, length: 6), actualRange: nil)
        let onView = editor.textView.convert(editor.window.convertFromScreen(whole), from: nil)
        #expect(highlight.contains(onView.insetBy(dx: 0.5, dy: 2)), "подсветка \(highlight) не накрывает запрос \(onView)")
        editor.press(#selector(NSResponder.moveRight(_:)))
        #expect(editor.textView.popups.isOpen)
        expectItemsMatch("загол", in: editor)
    }

    @Test("Курсор сразу за «/» — ещё в запросе; левее «/» меню закрывается")
    func caretLeavesQuery() throws {
        let editor = try openMenu(typing: "/загол")
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(editor.textView.popups.isOpen)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!editor.textView.popups.isOpen)
        #expect(editor.texts == ["/загол"])
    }

    @Test("Щелчок внутри запроса и выделение его части оставляют меню открытым")
    func clickAndSelectionInsideQuery() throws {
        let editor = try openMenu(typing: "/загол")
        editor.textView.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(editor.textView.popups.isOpen)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 3))
        #expect(editor.textView.popups.isOpen)
        expectItemsMatch("загол", in: editor)
    }

    @Test("Курсор ушёл в другой блок — меню закрывается")
    func caretInOtherBlock() throws {
        let editor = try EditorFixture([.paragraph("Выше"), .paragraph()])
        editor.placeCaret(inBlock: 1)
        editor.type("/за")
        #expect(editor.textView.popups.isOpen)
        editor.placeCaret(inBlock: 0)
        #expect(!editor.textView.popups.isOpen)
    }

    @Test("⌫ и ввод в середине запроса меняют запрос, меню следует за ним")
    func editInMiddle() throws {
        let editor = try openMenu(typing: "/чк")
        moveLeft(editor, 1)
        editor.type("е")
        #expect(editor.textView.popups.isOpen)
        expectItemsMatch("чек", in: editor)
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.textView.popups.isOpen)
        #expect(editor.texts == ["/чк"])
        expectItemsMatch("чк", in: editor)
    }

    @Test("Выбор пункта с курсором в середине запроса убирает «/» и весь запрос")
    func choosingRemovesWholeQuery() throws {
        let editor = try openMenu(typing: "/чк")
        moveLeft(editor, 1)
        editor.type("е")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(!editor.textView.popups.isOpen)
        #expect(editor.kinds == [.checkbox])
        #expect(editor.texts == [""])
        editor.undo()
        #expect(editor.kinds == [.paragraph])
    }

    @Test("Стёрли сам «/» — меню закрывается")
    func deletingSlashCloses() throws {
        let editor = try openMenu(typing: "/за")
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(!editor.textView.popups.isOpen)
        #expect(editor.texts == ["за"])
    }

    @Test("Пробел сразу после «/» закрывает меню")
    func spaceAfterSlashCloses() throws {
        let editor = try openMenu(typing: "/")
        editor.type(" ")
        #expect(!editor.textView.popups.isOpen)
        #expect(editor.texts == ["/ "])
    }

    @Test("Ничего не нашлось: меню открыто с одной строкой «Закрыть меню»; Esc закрывает и оставляет текст")
    func noResultsKeepsMenuOpen() throws {
        let editor = try openMenu(typing: "/нетакого")
        #expect(editor.textView.popups.isOpen)
        #expect(editor.textView.popups.visibleItems.isEmpty)
        #expect(editor.textView.popups.hasNoItems)
        // Правка запроса снова находит пункты.
        for _ in 0..<8 { editor.press(#selector(NSResponder.deleteBackward(_:))) }
        #expect(editor.textView.popups.isOpen)
        #expect(!editor.textView.popups.hasNoItems)
        editor.type("жук")
        #expect(editor.textView.popups.hasNoItems)
        editor.press(#selector(NSResponder.cancelOperation(_:)))
        #expect(!editor.textView.popups.isOpen)
        #expect(editor.texts == ["/жук"])
    }

    @Test("Enter, когда ничего не нашлось, закрывает меню и работает как обычный Enter")
    func enterWithNoResults() throws {
        let editor = try openMenu(typing: "/нетакого")
        editor.press(#selector(NSResponder.insertNewline(_:)))
        #expect(!editor.textView.popups.isOpen)
        #expect(editor.texts == ["/нетакого", ""])
    }
}
