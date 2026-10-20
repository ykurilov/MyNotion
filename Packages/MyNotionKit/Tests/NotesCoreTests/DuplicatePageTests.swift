import Foundation
import Testing
@testable import NotesCore

/// «Дублировать» страницу (contracts/page-operations.md, «Дублирование»): название «(1)» и следующий свободный номер,
/// место сразу под оригиналом, ссылка в родителе сразу за ссылкой оригинала, копия шаблона — шаблон, ⌘Z — копия
/// стёрта одной правкой. Что именно копируется, проверяет `PageBranchCopierTests`.
@MainActor
@Suite("Дублирование страницы")
struct DuplicatePageTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let tree: PageTreeOperations

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        tree = PageTreeOperations(store: store)
    }

    /// Родитель «Проекты» со ссылками на «Альфа», «Бета» и абзацем после них; у «Альфа» — подстраница и текст.
    private func projects() throws -> (parent: Page, alpha: Page, beta: Page, alphaChild: Page) {
        try store.write { tx in
            let parent = try tx.createPage(title: "Проекты")
            let alpha = try tx.createPage(title: "Альфа", parentId: parent.id)
            let beta = try tx.createPage(title: "Бета", parentId: parent.id)
            let alphaChild = try tx.createPage(title: "Внутри альфы", parentId: alpha.id)
            for block in try tx.blocks(ofPage: parent.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for linked in [alpha.id, beta.id] {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: parent.id, kind: .pageLink, linkedPageId: linked, sortKey: key!))
            }
            key = .between(key, nil)
            try tx.insertBlock(Block(pageId: parent.id, text: InlineText("после ссылок"), sortKey: key!))
            var first = try #require(try tx.blocks(ofPage: alpha.id).first)
            first.text = InlineText("текст альфы")
            try tx.updateBlock(first)
            try tx.insertBlock(Block(pageId: alpha.id, kind: .pageLink, linkedPageId: alphaChild.id, sortKey: .between(first.sortKey, nil)))
            return (parent, alpha, beta, alphaChild)
        }
    }

    /// Блоки страницы: текст или «→ название подстраницы».
    private func outline(_ pageId: UUID) throws -> [String] {
        let titles = Dictionary(uniqueKeysWithValues: try store.pageOutline().map { ($0.id, $0.title) })
        return try #require(try store.pageContent(pageId)).blocks.map { block in
            block.kind == .pageLink ? "→ \(block.linkedPageId.flatMap { titles[$0] } ?? "?")" : block.text.string
        }
    }

    private func childTitles(_ parentId: UUID?) throws -> [String] {
        try store.pageTree().children(of: parentId).map(\.title)
    }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager
        return undoManager
    }

    @Test("Копия — «Название (1)» сразу под оригиналом; подстраницы копии — с прежними названиями")
    func copyGoesRightBelowOriginal() async throws {
        let (parent, alpha, _, _) = try projects()

        let copy = try await tree.duplicate(alpha.id)

        #expect(copy.title == "Альфа (1)")
        #expect(copy.parentId == parent.id)
        #expect(try childTitles(parent.id) == ["Альфа", "Альфа (1)", "Бета"])
        #expect(try childTitles(copy.id) == ["Внутри альфы"])
        #expect(try outline(copy.id) == ["текст альфы", "→ Внутри альфы"])
        let copiedChild = try #require(try store.pageTree().children(of: copy.id).first)
        #expect(copiedChild.id != alpha.id)
    }

    @Test("В родителе ссылка на копию — сразу за ссылкой на оригинал")
    func linkGoesRightAfterOriginalLink() async throws {
        let (parent, alpha, _, _) = try projects()

        _ = try await tree.duplicate(alpha.id)

        #expect(try outline(parent.id) == ["→ Альфа", "→ Альфа (1)", "→ Бета", "после ссылок"])
    }

    @Test("Занятый номер — следующий свободный: «(1)» есть → «(2)»")
    func takenNumberGoesToNextFree() async throws {
        let (parent, alpha, _, _) = try projects()

        let first = try await tree.duplicate(alpha.id)
        let second = try await tree.duplicate(alpha.id)

        #expect(first.title == "Альфа (1)")
        #expect(second.title == "Альфа (2)")
        #expect(try childTitles(parent.id) == ["Альфа", "Альфа (2)", "Альфа (1)", "Бета"])
    }

    @Test("Страница верхнего уровня: копия — сразу под ней в корне, без ссылок")
    func rootPageCopyStaysInRoot() async throws {
        let (first, second) = try store.write { tx in (try tx.createPage(title: "Один"), try tx.createPage(title: "Два")) }

        let copy = try await tree.duplicate(first.id)

        #expect(copy.parentId == nil)
        #expect(try childTitles(nil) == ["Один", "Один (1)", "Два"])
        #expect(try store.pageTree().page(second.id) != nil)
    }

    @Test("Копия шаблона — тоже шаблон")
    func templateCopyIsTemplate() async throws {
        let template = try store.write { tx in
            var page = try tx.createPage(title: "Встреча")
            page.isTemplate = true
            return try tx.updatePage(page)
        }

        let copy = try await tree.duplicate(template.id)

        #expect(copy.isTemplate)
        #expect(copy.title == "Встреча (1)")
    }

    @Test("Страницы нет — ошибка, ничего не создано")
    func missingPageThrows() async throws {
        _ = try projects()
        let before = try store.pageOutline().count

        await #expect(throws: NotesStoreError.self) { try await tree.duplicate(UUID()) }
        #expect(try store.pageOutline().count == before)
    }

    @Test("⌘Z стирает копию с подстраницами и ссылкой одной правкой; ⇧⌘Z — копия снова на месте")
    func undoErasesCopyInOneStep() async throws {
        let (parent, alpha, _, _) = try projects()
        let pagesBefore = try store.pageOutline().count
        let undoManager = makeUndoManager()

        undoManager.beginUndoGrouping()
        let copy = try await tree.duplicate(alpha.id)
        undoManager.endUndoGrouping()
        #expect(try store.pageOutline().count == pagesBefore + 2)

        undoManager.undo()
        #expect(try store.pageOutline().count == pagesBefore, "Копия и её подстраница стёрты, не в корзине")
        #expect(try store.pageOutline().contains { $0.id == copy.id } == false)
        #expect(try outline(parent.id) == ["→ Альфа", "→ Бета", "после ссылок"])
        #expect(!undoManager.canUndo)

        undoManager.redo()
        #expect(try childTitles(parent.id) == ["Альфа", "Альфа (1)", "Бета"])
        #expect(try outline(parent.id) == ["→ Альфа", "→ Альфа (1)", "→ Бета", "после ссылок"])
        let redone = try #require(try store.pageTree().children(of: parent.id).first { $0.title == "Альфа (1)" })
        #expect(try childTitles(redone.id) == ["Внутри альфы"])

        undoManager.undo()
        #expect(try store.pageOutline().count == pagesBefore)
    }

    @Test("Удаление копии навсегда не трогает оригинал: текст ветки тот же")
    func erasingCopyKeepsOriginal() async throws {
        let (_, alpha, _, alphaChild) = try projects()
        let before = (try outline(alpha.id), try outline(alphaChild.id))

        let copy = try await tree.duplicate(alpha.id)
        try tree.moveToTrash(copy.id)
        try tree.deleteForever(copy.id)

        #expect(try outline(alpha.id) == before.0)
        #expect(try outline(alphaChild.id) == before.1)
        #expect(try childTitles(alpha.id) == ["Внутри альфы"])
    }

    @Test("После копии окно узнаёт затронутые страницы: копию и родителя")
    func reportsTouchedPages() async throws {
        let (parent, alpha, _, _) = try projects()
        var touched: Set<UUID> = []
        tree.onChange = { touched.formUnion($0) }

        let copy = try await tree.duplicate(alpha.id)

        #expect(touched.contains(copy.id))
        #expect(touched.contains(parent.id))
    }
}
