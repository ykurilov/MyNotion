import AppKit
import Testing
import VisualStyle
@testable import NotesCore
@testable import PageEditor

/// Скелет блока встроенной базы (T026): «/База данных — встроенная» и «— на всю страницу» в меню «/», выбор — запрос
/// владельцу окна (базу создают операции `Databases`), «/» с набранным стирается; блок `database` — вид-вложение.
@MainActor
@Suite("Блок базы в редакторе")
struct DatabaseBlockTests {
    @Test("Два пункта «/» по словам «база», «database», «таблица» (простая таблица — первой)")
    func slashItems() {
        let titles = PopupMenuItem.slashItems(matching: "база").map(\.title)
        #expect(titles == ["База данных — встроенная", "База данных — на всю страницу"])
        #expect(PopupMenuItem.slashItems(matching: "database").map(\.action) == [.insertDatabase(inline: true), .insertDatabase(inline: false)])
        #expect(BlockKind.database.rendersAsAttachment)
        #expect(PopupMenuItem.slashItems(matching: "табл").map(\.action) == [.insertTable, .insertDatabase(inline: true), .insertDatabase(inline: false)])
    }

    @Test("Выбор в меню «/» — запрос «создать базу» у блока: пустой — заменить, с текстом — после него")
    func requestsCreation() throws {
        for (text, inline) in [("", true), ("дело", false)] {
            let editor = try EditorFixture([.paragraph(text)])
            var requests: [SubpageRequest] = []
            editor.textView.onSubpageRequest = { requests.append($0) }
            editor.placeCaret(inBlock: 0, at: nil)
            editor.type(text.isEmpty ? "/база" : " /база")
            if !inline { editor.press(#selector(NSResponder.moveDown(_:))) }
            editor.press(#selector(NSResponder.insertNewline(_:)))
            let blockId = editor.textView.document.blocks[0].id
            #expect(requests == [.createDatabase(text.isEmpty ? .replacing(blockId: blockId) : .after(blockId: blockId), isInline: inline)])
            #expect(editor.texts == [text.isEmpty ? "" : text + " "], "набранное «/база» стёрто")
        }
    }
}
