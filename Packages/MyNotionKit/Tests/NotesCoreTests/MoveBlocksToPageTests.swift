import Foundation
import Testing
@testable import NotesCore

/// «Переместить в» для блоков (contracts/page-operations.md, «Перенос блоков»): выделенные блоки с поддеревьями
/// и контейнерами — в конец страницы-цели копиями с `movedFrom`; исходные удалены; подстраницы, чьи ссылки переехали,
/// — под целью; ⌘Z — исходные с прежними id, копий нет, подстраницы — у прежнего родителя.
@MainActor
@Suite("Перенос блоков на другую страницу")
struct MoveBlocksToPageTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let tree: PageTreeOperations

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        tree = PageTreeOperations(store: store)
    }

    struct Pages {
        var source: Page, target: Page, subpage: Page
        /// Блоки потока исходной страницы по порядку.
        var blocks: [Block]
        var columnList: Block
    }

    /// Исходная: «до», «Список» › «пункт 1» › «пункт 1.1», «Второй», колонки с текстом, ссылка на подстраницу, «после».
    /// Цель: «у цели».
    private func pages() throws -> Pages {
        try store.write { tx in
            let source = try tx.createPage(title: "Исходная")
            let target = try tx.createPage(title: "Цель")
            let subpage = try tx.createPage(title: "Подстраница", parentId: source.id)
            for block in try tx.blocks(ofPage: source.id) { try tx.deleteBlock(block.id) }
            var targetFirst = try #require(try tx.blocks(ofPage: target.id).first)
            targetFirst.text = InlineText("у цели")
            try tx.updateBlock(targetFirst)
            var key: FractionalSortKey?
            func add(_ kind: BlockKind = .paragraph, _ text: String = "", indent: Int = 0, linked: UUID? = nil) throws -> Block {
                key = .between(key, nil)
                return try tx.insertBlock(Block(pageId: source.id, kind: kind, text: InlineText(text), indent: indent,
                                                linkedPageId: linked, sortKey: key!))
            }
            var blocks = [try add(.paragraph, "до")]
            blocks.append(try add(.toggle, "Список"))
            blocks.append(try add(.bulletItem, "пункт 1", indent: 1))
            blocks.append(try add(.bulletItem, "пункт 1.1", indent: 2))
            blocks.append(try add(.paragraph, "Второй"))
            let columnList = try add(.columnList)
            blocks.append(columnList)
            var columnKey: FractionalSortKey?
            for number in 1...2 {
                columnKey = .between(columnKey, nil)
                let column = try tx.insertBlock(Block(pageId: source.id, kind: .column, sortKey: columnKey!, containerId: columnList.id))
                try tx.insertBlock(Block(pageId: source.id, text: InlineText("в колонке \(number)"), sortKey: .between(nil, nil),
                                         containerId: column.id))
            }
            blocks.append(try add(.pageLink, linked: subpage.id))
            blocks.append(try add(.paragraph, "после"))
            return Pages(source: source, target: target, subpage: subpage, blocks: blocks, columnList: columnList)
        }
    }

    /// Поток страницы: «отступ:текст» или «отступ:→ название».
    private func flow(_ pageId: UUID) throws -> [String] {
        let titles = Dictionary(uniqueKeysWithValues: try store.pageOutline().map { ($0.id, $0.title) })
        return try #require(try store.pageContent(pageId)).blocks.filter { $0.containerId == nil }.map { block in
            let text = block.kind == .pageLink ? "→ \(block.linkedPageId.flatMap { titles[$0] } ?? "?")" : block.text.string
            return "\(block.indent):\(text)"
        }
    }

    private func blocks(_ pageId: UUID) throws -> [Block] {
        try #require(try store.pageContent(pageId)).blocks
    }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager
        return undoManager
    }

    @Test("Выделенные блоки с поддеревьями — в конец цели, глубина первого — 0; у исходной их больше нет")
    func movesSelectionWithSubtreesToTheEnd() throws {
        let pages = try pages()
        let list = pages.blocks[1], second = pages.blocks[4]

        try tree.moveBlocks([list.id, second.id], from: pages.source.id, to: pages.target.id)

        #expect(try flow(pages.target.id) == ["0:у цели", "0:Список", "1:пункт 1", "2:пункт 1.1", "0:Второй"])
        #expect(try flow(pages.source.id) == ["0:до", "0:", "0:→ Подстраница", "0:после"])
    }

    @Test("Глубины — относительно первого: вложенный пункт без родителя встаёт на 0, его дети — на 1")
    func indentsRelativeToFirst() throws {
        let pages = try pages()

        try tree.moveBlocks([pages.blocks[2].id], from: pages.source.id, to: pages.target.id)

        #expect(try flow(pages.target.id) == ["0:у цели", "0:пункт 1", "1:пункт 1.1"])
        #expect(try flow(pages.source.id) == ["0:до", "0:Список", "0:Второй", "0:", "0:→ Подстраница", "0:после"])
    }

    @Test("Ребёнок, выделенный вместе с родителем, переносится один раз")
    func childSelectedWithParentMovesOnce() throws {
        let pages = try pages()

        try tree.moveBlocks([pages.blocks[1].id, pages.blocks[2].id], from: pages.source.id, to: pages.target.id)

        #expect(try flow(pages.target.id) == ["0:у цели", "0:Список", "1:пункт 1", "2:пункт 1.1"])
    }

    @Test("Колонки едут со своими потоками; у каждой копии movedFrom — id исходного блока, id новые")
    func containersMoveWithFlowsAndMovedFrom() throws {
        let pages = try pages()
        let originalIds = Set(try blocks(pages.source.id).map(\.id))

        try tree.moveBlocks([pages.columnList.id], from: pages.source.id, to: pages.target.id)

        let moved = try blocks(pages.target.id).filter { $0.text.string != "у цели" }
        #expect(moved.map(\.kind).filter { $0 == .column }.count == 2)
        #expect(Set(moved.map(\.text.string)).isSuperset(of: ["в колонке 1", "в колонке 2"]))
        #expect(moved.allSatisfy { !originalIds.contains($0.id) })
        #expect(moved.allSatisfy { $0.props.movedFrom.map(originalIds.contains) == true })
        #expect(try blocks(pages.source.id).allSatisfy { $0.kind != .column && $0.kind != .columnList })
        #expect(!(try blocks(pages.source.id).contains { $0.text.string.hasPrefix("в колонке") }))
    }

    @Test("Ссылка на подстраницу переезжает — подстраница теперь под целью")
    func subpageMovesUnderTarget() throws {
        let pages = try pages()

        try tree.moveBlocks([pages.blocks[6].id], from: pages.source.id, to: pages.target.id)

        #expect(try store.pageTree().parentId(of: pages.subpage.id) == pages.target.id)
        #expect(try flow(pages.target.id) == ["0:у цели", "0:→ Подстраница"])
        #expect(!(try flow(pages.source.id).contains("0:→ Подстраница")))
    }

    @Test("⌘Z — исходные блоки с прежними id на прежних местах, копий нет, подстраница — у прежнего родителя; ⇧⌘Z — снова")
    func undoRestoresOriginalsWithSameIds() throws {
        let pages = try pages()
        let sourceBefore = try blocks(pages.source.id)
        let targetBefore = try blocks(pages.target.id)
        let undoManager = makeUndoManager()

        undoManager.beginUndoGrouping()
        try tree.moveBlocks([pages.blocks[1].id, pages.columnList.id, pages.blocks[6].id], from: pages.source.id, to: pages.target.id)
        undoManager.endUndoGrouping()
        let movedFlow = try flow(pages.target.id)

        undoManager.undo()
        #expect(try blocks(pages.source.id).map(\.id) == sourceBefore.map(\.id))
        #expect(try blocks(pages.source.id).map(\.text) == sourceBefore.map(\.text))
        #expect(try blocks(pages.target.id).map(\.id) == targetBefore.map(\.id))
        #expect(try store.pageTree().parentId(of: pages.subpage.id) == pages.source.id)
        #expect(!undoManager.canUndo)

        undoManager.redo()
        #expect(try flow(pages.target.id) == movedFlow)
        #expect(try store.pageTree().parentId(of: pages.subpage.id) == pages.target.id)
    }

    @Test("Цель — сама исходная страница: ошибка, ничего не меняется")
    func sameTargetRejected() throws {
        let pages = try pages()
        let before = try flow(pages.source.id)

        #expect(throws: NotesStoreError.self) {
            try tree.moveBlocks([pages.blocks[0].id], from: pages.source.id, to: pages.source.id)
        }
        #expect(try flow(pages.source.id) == before)
    }

    @Test("Все блоки страницы ушли — на ней остаётся пустой абзац")
    func emptiedSourceKeepsParagraph() throws {
        let pages = try pages()
        let all = try blocks(pages.source.id).filter { $0.containerId == nil }.map(\.id)

        try tree.moveBlocks(all, from: pages.source.id, to: pages.target.id)

        #expect(try flow(pages.source.id) == ["0:"])
    }
}
