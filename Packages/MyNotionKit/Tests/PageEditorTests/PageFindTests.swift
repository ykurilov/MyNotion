import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// ⌘F по всей странице (research R4): один `NSTextFinderClient` склеивает текст потока страницы, колонок и ячеек;
/// переход к совпадению ставит выделение в нужный редактор и раскрывает свёрнутое.
@MainActor
@Suite("Поиск на странице ⌘F")
struct PageFindTests {
    typealias Spec = EditorFixture.Spec

    /// «Начало», свёрнутый переключатель с «спрятано слово», колонки «[слово слева | справа]», таблица со «слово в ячейке».
    func fixture() throws -> EditorFixture {
        let editor = try EditorFixture([.paragraph("Начало слово"), Spec(kind: .toggle, text: "Переключатель"),
                                        Spec(kind: .paragraph, text: "спрятано слово", indent: 1),
                                        .paragraph("слово слева"), .paragraph("справа"), .paragraph("перед таблицей"), .paragraph("конец")])
        let ids = editor.document.blocks.map(\.id)
        editor.textView.setCollapsed(true, ofBlock: ids[1])
        editor.step { editor.textView.placeBlocks([ids[4]], besideRightOf: ids[3]) }
        let tableIndex = try #require(editor.document.index(ofBlock: ids[5])) + 1
        editor.step { editor.textView.insertEmptyBlock(at: tableIndex, openingSlashMenu: false) }
        editor.step { editor.textView.insertTable(at: tableIndex) }
        let table = try #require(editor.document.blocks.first { $0.kind == .table })
        let grid = try #require(editor.document.tableGrid(table.id))
        editor.step { editor.document.apply(grid.settingText(InlineText("а тут слово в ячейке"), row: 1, column: 2)) }
        editor.window.makeFirstResponder(editor.textView)
        editor.layoutViewport()
        return editor
    }

    func matches(of word: String, in client: PageFindClient) -> [NSRange] {
        let string = client.string as NSString
        var ranges: [NSRange] = []
        var search = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: word, options: [], range: search)
            guard found.location != NSNotFound else { return ranges }
            ranges.append(found)
            search = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
        }
    }

    @Test("Текст поиска — вся страница по порядку показа: поток, свёрнутое, колонки, ячейки")
    func searchStringCoversAllFlows() throws {
        let editor = try fixture()
        let client = try #require(editor.textView.pageFindClient)
        let string = client.string
        for part in ["Начало слово", "спрятано слово", "слово слева", "справа", "а тут слово в ячейке", "конец"] {
            #expect(string.contains(part), "нет «\(part)»")
        }
        let order = ["Начало", "спрятано", "слева", "справа", "перед таблицей", "в ячейке", "конец"].map { (string as NSString).range(of: $0).location }
        #expect(order == order.sorted(), "порядок показа: \(order)")
        #expect(matches(of: "слово", in: client).count == 4)
    }

    @Test("Совпадение в колонке — выделение в редакторе колонки, рамки — в нём")
    func matchInColumn() throws {
        let editor = try fixture()
        let client = try #require(editor.textView.pageFindClient)
        let match = matches(of: "слово", in: client)[2]
        client.scrollRangeToVisible(match)
        client.selectedRanges = [NSValue(range: match)]
        let column = try #require(editor.window.firstResponder as? FlowTextView)
        #expect(column.string.hasPrefix("слово слева"))
        #expect(column.selectedRange() == NSRange(location: 0, length: 5))
        var effective = NSRange()
        #expect(client.contentView(at: match.location, effectiveCharacterRange: &effective) === column)
        #expect(!(client.rects(forCharacterRange: match) ?? []).isEmpty)
    }

    @Test("Совпадение в ячейке — поле правки ячейки с выделенным словом")
    func matchInCell() throws {
        let editor = try fixture()
        let client = try #require(editor.textView.pageFindClient)
        let match = matches(of: "слово", in: client)[3]
        client.scrollRangeToVisible(match)
        client.selectedRanges = [NSValue(range: match)]
        let cell = try #require(editor.window.firstResponder as? TableCellEditor)
        #expect(cell.table?.activeCell == TableCellPosition(row: 1, column: 2))
        #expect(cell.selectedRange() == NSRange(location: 6, length: 5))
        var effective = NSRange()
        #expect(client.contentView(at: match.location, effectiveCharacterRange: &effective) != nil)
    }

    @Test("Совпадение в свёрнутом раскрывает переключатель")
    func matchInCollapsed() throws {
        let editor = try fixture()
        let client = try #require(editor.textView.pageFindClient)
        let toggle = editor.document.blocks[1].id
        #expect(editor.textView.collapsedBlockIds.contains(toggle))
        let match = matches(of: "слово", in: client)[1]
        client.selectedRanges = [NSValue(range: match)]
        #expect(!editor.textView.collapsedBlockIds.contains(toggle))
        #expect(editor.window.firstResponder === editor.textView)
        let start = editor.textLocation(ofBlock: 2)
        #expect(editor.textView.selectedRange() == NSRange(location: start + 9, length: 5))
    }

    @Test("Переход по совпадениям туда и обратно; выделение в редакторе — выделение поиска")
    func navigateMatches() throws {
        let editor = try fixture()
        let client = try #require(editor.textView.pageFindClient)
        let all = matches(of: "слово", in: client)
        for match in all + all.reversed() {
            client.scrollRangeToVisible(match)
            client.selectedRanges = [NSValue(range: match)]
            #expect(client.firstSelectedRange == match)
        }
    }

    @Test("Правка текста — поиск видит новый текст")
    func stringFollowsEdits() throws {
        let editor = try fixture()
        let client = try #require(editor.textView.pageFindClient)
        _ = client.string
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type("!")
        #expect(client.string.hasPrefix("Начало слово!"))
    }

    @Test("Переход к найденному из поиска страниц: блок колонки — курсор в колонке, ячейка — поле правки ячейки (T111)")
    func revealFromPageSearch() throws {
        let editor = try fixture()
        let list = try #require(editor.document.blocks.first { $0.kind == .columnList })
        let right = editor.document.flow(editor.document.flow(list.id)[1].id)[0]
        editor.textView.revealBlock(right.id)
        let column = try #require(editor.window.firstResponder as? FlowTextView)
        #expect(column.document.index(ofBlock: right.id) == 0)

        let table = try #require(editor.document.blocks.first { $0.kind == .table })
        let cell = try #require(editor.document.tableGrid(table.id)?.cell(row: 1, column: 2))
        editor.textView.revealBlock(cell.id)
        let cellEditor = try #require(editor.window.firstResponder as? TableCellEditor)
        #expect(cellEditor.table?.activeCell == TableCellPosition(row: 1, column: 2))
    }

        @Test("⌘F открывает одну полосу поиска страницы, а не поиск отдельного редактора")
    func findBarIsPageWide() throws {
        let editor = try fixture()
        #expect(!editor.textView.usesFindBar)
        #expect(editor.textView.editorTree.allSatisfy { !$0.usesFindBar })
        let item = NSMenuItem(title: "Найти", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        #expect(editor.textView.validateMenuItem(item))
        editor.textView.performTextFinderAction(item)
        #expect(editor.textView.enclosingScrollView?.isFindBarVisible == true, "полоса поиска не показалась")
        // ⌘F из колонки — та же полоса страницы.
        let column = try #require(editor.textView.embeddedFlowEditors.first)
        let find = NSMenuItem(title: "Найти", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        #expect(column.validateMenuItem(find))
    }
}
