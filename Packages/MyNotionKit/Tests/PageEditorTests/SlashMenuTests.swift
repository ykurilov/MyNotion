import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

@MainActor
@Suite("Меню «/» и меню блока")
struct SlashMenuTests {
    @Test("Поиск по названию и словам-подсказкам без учёта регистра")
    func filtersItems() {
        #expect(PopupMenuItem.slashItems(matching: "").count == PopupMenuItem.blockKinds.count)
        #expect(PopupMenuItem.slashItems(matching: "Заго").map(\.action) == [.setKind(.heading1), .setKind(.heading2), .setKind(.heading3)])
        #expect(PopupMenuItem.slashItems(matching: "todo").map(\.action) == [.setKind(.checkbox)])
        #expect(PopupMenuItem.slashItems(matching: "h2").map(\.action) == [.setKind(.heading2)])
        #expect(PopupMenuItem.slashItems(matching: "нетакого").isEmpty)
    }

    @Test("«/» открывает меню, набор сужает список, Enter меняет тип и убирает набранное")
    func slashCommandChangesKind() throws {
        let editor = try EditorFixture([.paragraph("дело")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type(" /")
        #expect(editor.textView.popups.isOpen)

        editor.type("чек")
        #expect(editor.textView.popups.visibleItems.map(\.action) == [.setKind(.checkbox)])
        editor.press(#selector(NSResponder.insertNewline(_:)))

        #expect(!editor.textView.popups.isOpen)
        #expect(editor.kinds == [.checkbox])
        #expect(editor.texts == ["дело "])
    }

    @Test("Esc закрывает меню и оставляет набранный текст")
    func escapeClosesMenu() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)
        editor.type("/за")
        editor.press(#selector(NSResponder.cancelOperation(_:)))

        #expect(!editor.textView.popups.isOpen)
        #expect(editor.kinds == [.paragraph])
        #expect(editor.texts == ["/за"])
    }

    @Test("Стрелки выбирают пункт меню")
    func arrowsMoveSelection() throws {
        let editor = try EditorFixture([.paragraph()])
        editor.placeCaret(inBlock: 0)
        editor.type("/")
        editor.press(#selector(NSResponder.moveDown(_:)))
        editor.press(#selector(NSResponder.moveDown(_:)))
        editor.press(#selector(NSResponder.insertNewline(_:)))

        #expect(editor.kinds == [.heading2])
        #expect(editor.texts == [""])
    }
}
