import Foundation
import Testing
@testable import NotesCore

/// «/» → «Страница» и «Преобразовать в → Страница», как в Notion 7.39: подстраница с блоком-ссылкой там, где курсор.
@MainActor
@Suite("Подстраница на месте курсора")
struct InlineSubpageTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let tree: PageTreeOperations

    init() throws {
        folder = try TemporaryFolder()
        let clock = HybridLogicalClock(deviceId: UUID(), wallClock: AdjustableWallClock(millis: 1_000).reading)
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: clock)
        tree = PageTreeOperations(store: store)
    }

    /// Страница «Проекты» с блоками по порядку; первый блок — пустой абзац новой страницы, переделанный в первый текст.
    private func projects(_ texts: [String]) throws -> (page: UUID, blocks: [UUID]) {
        try store.write { tx in
            let page = try tx.createPage(title: "Проекты")
            var first = try #require(try tx.blocks(ofPage: page.id).first)
            first.text = InlineText(texts[0])
            try tx.updateBlock(first)
            var ids = [first.id]
            var last = first.sortKey
            for text in texts.dropFirst() {
                let block = try tx.insertBlock(Block(pageId: page.id, text: InlineText(text), sortKey: .between(last, nil)))
                last = block.sortKey
                ids.append(block.id)
            }
            return (page.id, ids)
        }
    }

    /// Блоки страницы по порядку: текст или «→ название подстраницы».
    private func outline(_ pageId: UUID) throws -> [String] {
        let titles = Dictionary(uniqueKeysWithValues: try store.pageOutline().map { ($0.id, $0.title) })
        return try #require(try store.pageContent(pageId)).blocks.map { block in
            block.kind == .pageLink ? "→ \(block.linkedPageId.flatMap { titles[$0] } ?? "?")" : block.text.string
        }
    }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager
        return undoManager
    }

    @discardableResult
    private func undoable<T>(_ undoManager: UndoManager, _ action: () throws -> T) rethrows -> T {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return try action()
    }

    @Test("Пустой абзац заменяется ссылкой на новую подстраницу; подстраница — под текущей страницей")
    func emptyParagraphBecomesLink() throws {
        let (page, blocks) = try projects(["до", "", "после"])

        let subpage = try tree.createSubpage(in: page, title: "Новая", linkAt: .replacing(blockId: blocks[1]))

        #expect(try outline(page) == ["до", "→ Новая", "после"])
        #expect(try store.pageTree().children(of: page).map(\.id) == [subpage.id])
        #expect(try store.pageContent(page)?.blocks.contains { $0.id == blocks[1] } == false)
    }

    @Test("Ссылка на месте блока берёт его отступ и поток (колонку, ячейку)")
    func linkKeepsIndentAndContainer() throws {
        let (page, blocks) = try projects(["пункт", ""])
        try store.write { tx in
            var block = try #require(try tx.block(blocks[1]))
            block.indent = 1
            try tx.updateBlock(block)
        }

        let subpage = try tree.createSubpage(in: page, linkAt: .replacing(blockId: blocks[1]))

        let link = try #require(try store.pageContent(page)?.blocks.first { $0.linkedPageId == subpage.id })
        #expect(link.indent == 1)
        #expect(link.containerId == nil)
    }

    @Test("В блоке с текстом ссылка встаёт следующим блоком, текст остаётся")
    func linkAfterBlockWithText() throws {
        let (page, blocks) = try projects(["первый", "второй"])

        try tree.createSubpage(in: page, title: "Новая", linkAt: .after(blockId: blocks[0]))

        #expect(try outline(page) == ["первый", "→ Новая", "второй"])
    }

    @Test("В дереве новая подстраница встаёт по порядку ссылок: между соседями, чьи ссылки до и после неё")
    func treeOrderFollowsLinks() throws {
        let (page, _) = try projects(["начало"])
        let first = try tree.createSubpage(in: page, title: "Первая")
        let second = try tree.createSubpage(in: page, title: "Вторая")
        let firstLink = try #require(try store.pageContent(page)?.blocks.first { $0.linkedPageId == first.id })

        let middle = try tree.createSubpage(in: page, title: "Средняя", linkAt: .after(blockId: firstLink.id))
        let top = try tree.createSubpage(in: page, title: "Верхняя", linkAt: .replacing(blockId: try #require(
            try store.pageContent(page)?.blocks.first?.id)))

        #expect(try outline(page) == ["→ Верхняя", "→ Первая", "→ Средняя", "→ Вторая"])
        #expect(try store.pageTree().children(of: page).map(\.id) == [top.id, first.id, middle.id, second.id])
    }

    @Test("Подписчик видит страницу, ссылку и убранный блок одной транзакцией")
    func oneTransaction() throws {
        let (page, blocks) = try projects(["до", ""])
        let recorder = RecordingHook()
        store.addWriteHook(recorder)

        try tree.createSubpage(in: page, linkAt: .replacing(blockId: blocks[1]))

        #expect(recorder.transactions.count == 1)
    }

    @Test("⌘Z — один шаг: подстраница в корзине, ссылки нет, прежний блок на месте; ⇧⌘Z возвращает всё как было")
    func undoRedo() throws {
        let undoManager = makeUndoManager()
        let (page, blocks) = try projects(["до", "", "после"])
        let subpage = try undoable(undoManager) {
            try tree.createSubpage(in: page, title: "Новая", linkAt: .replacing(blockId: blocks[1]))
        }
        let link = try #require(try store.pageContent(page)?.blocks.first { $0.linkedPageId == subpage.id })

        undoManager.undo()
        #expect(try outline(page) == ["до", "", "после"])
        #expect(try store.pageContent(page)?.blocks.map(\.id) == blocks)
        #expect(try store.trashEntries().map(\.id) == [subpage.id])
        #expect(!undoManager.canUndo)

        undoManager.redo()
        #expect(try outline(page) == ["до", "→ Новая", "после"])
        #expect(try store.pageContent(page)?.blocks.first { $0.linkedPageId == subpage.id }?.id == link.id)
        #expect(try store.trashEntries().isEmpty)
        #expect(try store.pageTree().children(of: page).map(\.id) == [subpage.id])

        undoManager.undo()
        #expect(try outline(page) == ["до", "", "после"])
    }

    @Test("⌘Z после набора в подстранице не стирает набранное: страница уходит в корзину целой")
    func undoKeepsSubpageContent() throws {
        let undoManager = makeUndoManager()
        let (page, blocks) = try projects(["до"])
        let subpage = try undoable(undoManager) { try tree.createSubpage(in: page, linkAt: .after(blockId: blocks[0])) }
        try store.write { tx in
            var block = try #require(try tx.blocks(ofPage: subpage.id).first)
            block.text = InlineText("важное")
            try tx.updateBlock(block)
        }

        undoManager.undo()

        #expect(try store.trashEntries().map(\.id) == [subpage.id])
        #expect(try store.pageContent(subpage.id)?.blocks.map(\.text.string) == ["важное"])
        #expect(try outline(page) == ["до"])
    }

    @Test("Преобразовать в страницу: блок становится ссылкой, его текст — названием; ⌘Z возвращает блок с текстом")
    func turnIntoPage() throws {
        let undoManager = makeUndoManager()
        let (page, blocks) = try projects(["до", "Мой план", "после"])

        let subpage = try undoable(undoManager) { try tree.turnIntoSubpage(blocks[1], in: page) }

        #expect(subpage.title == "Мой план")
        #expect(try outline(page) == ["до", "→ Мой план", "после"])
        undoManager.undo()
        #expect(try outline(page) == ["до", "Мой план", "после"])
        #expect(try store.pageContent(page)?.blocks.map(\.id) == blocks)
    }

    /// Страница «Проекты» из блоков по порядку (поток страницы).
    private func projects(blocks specs: [(BlockKind, String, Int)]) throws -> (page: UUID, blocks: [UUID]) {
        try store.write { tx in
            let page = try tx.createPage(title: "Проекты")
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var last: FractionalSortKey?
            var ids: [UUID] = []
            for (kind, text, indent) in specs {
                let block = try tx.insertBlock(Block(pageId: page.id, kind: kind, text: InlineText(text), indent: indent,
                                                     sortKey: .between(last, nil)))
                last = block.sortKey
                ids.append(block.id)
            }
            return (page.id, ids)
        }
    }

    private func blocks(_ pageId: UUID) throws -> [Block] {
        try #require(try store.pageContent(pageId)).blocks
    }

    @Test("Преобразовать в страницу блок с детьми: дети переезжают внутрь со своей вложенностью, типами, цветом и данными")
    func turnIntoPageMovesChildren() throws {
        let (page, ids) = try projects(blocks: [(.paragraph, "до", 0), (.toggle, "Раздел", 0), (.bulletItem, "пункт", 1),
                                                (.bulletItem, "под-пункт", 2), (.image, "", 1), (.paragraph, "после", 0)])
        try store.write { tx in
            var item = try #require(try tx.block(ids[2]))
            item.color = BlockColor(text: .red)
            try tx.updateBlock(item)
            var image = try #require(try tx.block(ids[4]))
            image.props.url = URL(string: "https://example.com/cat.png")
            try tx.updateBlock(image)
        }
        let originals = try blocks(page)

        let subpage = try tree.turnIntoSubpage(ids[1], in: page)

        #expect(subpage.title == "Раздел")
        #expect(try outline(page) == ["до", "→ Раздел", "после"])
        let moved = try blocks(subpage.id)
        #expect(moved.map(\.text.string) == ["пункт", "под-пункт", ""])
        #expect(moved.map(\.kind) == [.bulletItem, .bulletItem, .image])
        #expect(moved.map(\.indent) == [0, 1, 0])
        #expect(moved[0].color == BlockColor(text: .red))
        #expect(moved[2].props == originals[4].props)
        #expect(Set(moved.map(\.id)).isDisjoint(with: ids), "У переехавших свои id: старые остаются пометками удаления")
    }

    @Test("Ребёнок-колонки переезжает со своими колонками и их блоками")
    func turnIntoPageMovesContainers() throws {
        let (page, ids) = try projects(blocks: [(.toggle, "Раздел", 0), (.columnList, "", 1), (.paragraph, "после", 0)])
        try store.write { tx in
            let column = try tx.insertBlock(Block(pageId: page, kind: .column, sortKey: .between(nil, nil), containerId: ids[1]))
            try tx.insertBlock(Block(pageId: page, text: InlineText("в колонке"), sortKey: .between(nil, nil), containerId: column.id))
        }

        let subpage = try tree.turnIntoSubpage(ids[0], in: page)

        let moved = try blocks(subpage.id)
        let list = try #require(moved.first { $0.kind == .columnList })
        let column = try #require(moved.first { $0.kind == .column })
        let inner = try #require(moved.first { $0.text.string == "в колонке" })
        #expect(list.containerId == nil && list.indent == 0)
        #expect(column.containerId == list.id)
        #expect(inner.containerId == column.id)
        #expect(try blocks(page).map(\.kind) == [.pageLink, .paragraph], "В родителе от колонок ничего не осталось")
    }

    @Test("Ссылка-ребёнок переезжает вместе со своей страницей: та становится подстраницей новой")
    func turnIntoPageMovesLinkedSubpages() throws {
        let (page, ids) = try projects(blocks: [(.toggle, "Раздел", 0), (.paragraph, "после", 0)])
        let inner = try tree.createSubpage(in: page, title: "Внутри", linkAt: .after(blockId: ids[0]))
        try store.write { tx in
            var link = try #require(try tx.blocks(ofPage: page).first { $0.linkedPageId == inner.id })
            link.indent = 1
            try tx.updateBlock(link)
        }

        let subpage = try tree.turnIntoSubpage(ids[0], in: page)

        #expect(try store.pageTree().parentId(of: inner.id) == subpage.id)
        #expect(try outline(subpage.id) == ["→ Внутри"])
        #expect(try outline(page) == ["→ Раздел", "после"])
    }

    @Test("⌘Z после переезда детей — один шаг: блоки на месте с прежними id, страница-ребёнок у прежнего родителя; ⇧⌘Z снова")
    func turnIntoPageWithChildrenUndoRedo() throws {
        let (page, ids) = try projects(blocks: [(.toggle, "Раздел", 0), (.bulletItem, "пункт", 1), (.paragraph, "после", 0)])
        let inner = try tree.createSubpage(in: page, title: "Внутри", linkAt: .after(blockId: ids[1]))
        try store.write { tx in
            var link = try #require(try tx.blocks(ofPage: page).first { $0.linkedPageId == inner.id })
            link.indent = 1
            try tx.updateBlock(link)
        }
        let undoManager = makeUndoManager()
        let before = try blocks(page).map(\.id)
        let innerSortKey = try #require(try store.pageTree().page(inner.id)).sortKey

        let subpage = try undoable(undoManager) { try tree.turnIntoSubpage(ids[0], in: page) }
        undoManager.undo()

        #expect(try blocks(page).map(\.id) == before)
        #expect(try outline(page) == ["Раздел", "пункт", "→ Внутри", "после"])
        #expect(try store.pageTree().parentId(of: inner.id) == page)
        #expect(try store.pageTree().page(inner.id)?.sortKey == innerSortKey)
        #expect(try store.trashEntries().map(\.id) == [subpage.id])
        #expect(!undoManager.canUndo)

        undoManager.redo()
        #expect(try outline(page) == ["→ Раздел", "после"])
        #expect(try outline(subpage.id) == ["пункт", "→ Внутри"])
        #expect(try store.pageTree().parentId(of: inner.id) == subpage.id)
        undoManager.undo()
        #expect(try outline(page) == ["Раздел", "пункт", "→ Внутри", "после"])
    }

    @Test("Подстраница на месте блока несуществующей страницы или блока не создаётся")
    func needsBlock() throws {
        let (page, _) = try projects(["до"])
        let missing = UUID(uuidString: "00000000-0000-7000-8000-0000000000BB")!

        #expect(throws: NotesStoreError.blockNotFound(missing)) {
            try tree.createSubpage(in: page, linkAt: .after(blockId: missing))
        }
        #expect(try store.pageTree().children(of: page).isEmpty)
    }
}
