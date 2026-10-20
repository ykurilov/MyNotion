import Foundation
import Testing
@testable import NotesCore

/// Ничего не теряется туда и обратно (SC-208, quickstart.md): на эталонной «богатой» странице — тысяча блоков, переключатель
/// с детьми, колонки, выноска, подстраница, обложка, иконка, широкая страница и мелкий шрифт — каждая пара «сделал → вернул»
/// оставляет текст, блоки и поля исходных страниц такими же, как в начале. Восстановление версии живёт в модуле
/// `PageVersions`, его круг — в `PageVersionsTests/NoLossRestoreTests`. Сами операции подробно проверяют соседние наборы.
@MainActor
@Suite("Без потерь: туда и обратно")
struct NoLossRoundTripTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let tree: PageTreeOperations

    init() throws {
        folder = try TemporaryFolder()
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        tree = PageTreeOperations(store: store)
    }

    /// Всё, что видит пользователь в странице и в блоках; служебные часы полей (`fieldClocks`) не в счёт.
    struct Fingerprint: Equatable {
        struct PageFields: Equatable {
            var title: String, icon: String?, parentId: UUID?, sortKey: FractionalSortKey, trashed: Bool
            var cover: PageCover?, isFullWidth: Bool, isSmallText: Bool, isTemplate: Bool
        }
        struct BlockFields: Equatable {
            var id: UUID, kind: BlockKind, text: InlineText, indent: Int, isChecked: Bool, linkedPageId: UUID?
            var sortKey: FractionalSortKey, containerId: UUID?, color: BlockColor, props: BlockProps
        }
        var page: PageFields
        var blocks: [BlockFields]
    }

    private func fingerprint(_ pageId: UUID) throws -> Fingerprint {
        let content = try #require(try store.pageContent(pageId))
        let page = content.page
        return Fingerprint(
            page: .init(title: page.title, icon: page.icon, parentId: page.parentId, sortKey: page.sortKey, trashed: page.trashedAt != nil,
                        cover: page.cover, isFullWidth: page.isFullWidth, isSmallText: page.isSmallText, isTemplate: page.isTemplate),
            blocks: content.blocks.map {
                .init(id: $0.id, kind: $0.kind, text: $0.text, indent: $0.indent, isChecked: $0.isChecked, linkedPageId: $0.linkedPageId,
                      sortKey: $0.sortKey, containerId: $0.containerId, color: $0.color, props: $0.props)
            })
    }

    private func texts(_ pageId: UUID) throws -> [String] {
        try #require(try store.pageContent(pageId)).blocks.map(\.text.string)
    }

    /// Устройство страницы без id (у копии они новые): поток по порядку, у контейнеров — их содержимое сразу под ними.
    private func structure(_ pageId: UUID) throws -> [String] {
        let blocks = try #require(try store.pageContent(pageId)).blocks
        let byContainer = Dictionary(grouping: blocks, by: \.containerId)
        func walk(_ containerId: UUID?, depth: Int) -> [String] {
            (byContainer[containerId] ?? []).sorted { $0.sortKey < $1.sortKey }.flatMap { block in
                ["\(depth)|\(block.kind)|\(block.indent)|\(block.text.string)|\(block.color)|\(block.props)"]
                    + walk(block.id, depth: depth + 1)
            }
        }
        return walk(nil, depth: 0)
    }

    private func makeUndoManager() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager
        return undoManager
    }

    /// Одна правка пользователя — одна группа отмены.
    private func undoable(_ undoManager: UndoManager, _ action: () async throws -> Void) async rethrows {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        try await action()
    }

    /// Эталон: богатая страница с обложкой из галереи, иконкой, широкой и мелкой; в ней подстраница с текстом.
    private func richPage() throws -> (page: UUID, subpage: UUID) {
        let part = RichPageGeneratorTests.part
        let pageId = try RichPageGenerator(parts: [part]).ensure(in: store)
        try store.write { tx in
            var page = try #require(try tx.page(pageId))
            page.icon = "🧪"
            page.cover = PageCover(source: .gallery("gradient_3"), offset: 0.3)
            page.isFullWidth = true
            page.isSmallText = true
            try tx.updatePage(page)
        }
        let subpage = try tree.createSubpage(in: pageId, title: "Внутри эталона")
        try store.write { tx in
            var first = try #require(try tx.blocks(ofPage: subpage.id).first)
            first.text = InlineText("текст подстраницы")
            try tx.updateBlock(first)
        }
        return (pageId, subpage.id)
    }

    @Test("Дублировать → удалить копию: исходная страница и её подстраница те же; ⌘Z и «удалить навсегда» — оба пути")
    func duplicateThenDeleteCopy() async throws {
        let (pageId, subpageId) = try richPage()
        let pageBefore = try fingerprint(pageId)
        let subpageBefore = try fingerprint(subpageId)
        let undoManager = makeUndoManager()

        // Путь 1: копия стёрта отменой.
        var copy: Page!
        try await undoable(undoManager) { copy = try await tree.duplicate(pageId) }
        #expect(copy.title == "\(RichPageGenerator.title) (1)")
        #expect(try structure(copy.id) == (try structure(pageId)), "Копия — те же блоки и текст")
        #expect(try fingerprint(pageId) == pageBefore, "Дублирование исходную не меняет")
        undoManager.undo()
        #expect(try store.pageTree().page(copy.id) == nil)
        #expect(try fingerprint(pageId) == pageBefore)
        #expect(try fingerprint(subpageId) == subpageBefore)

        // Путь 2: копия в корзину и навсегда.
        var second: Page!
        try await undoable(undoManager) { second = try await tree.duplicate(pageId) }
        try await undoable(undoManager) {
            try tree.moveToTrash(second.id)
            try tree.deleteForever(second.id)
        }
        #expect(try store.pageTree().page(second.id) == nil)
        #expect(try fingerprint(pageId) == pageBefore)
        #expect(try fingerprint(subpageId) == subpageBefore)
    }

    @Test("Перенести блоки → ⌘Z: исходная страница с прежними id, глубиной и порядком; у цели — как было; подстраница у прежнего родителя")
    func moveBlocksThenUndo() throws {
        let (pageId, subpageId) = try richPage()
        let target = try store.write { tx -> Page in
            let target = try tx.createPage(title: "Цель")
            var first = try #require(try tx.blocks(ofPage: target.id).first)
            first.text = InlineText("у цели")
            try tx.updateBlock(first)
            return target
        }
        let sourceBefore = try fingerprint(pageId)
        let targetBefore = try fingerprint(target.id)
        let subpageBefore = try fingerprint(subpageId)
        let flow = try #require(try store.pageContent(pageId)).blocks.filter { $0.containerId == nil }
        let toggle = try #require(flow.first { $0.kind == .toggle && $0.text.string == "Свёрнутый переключатель" })
        let columns = try #require(flow.first { $0.kind == .columnList })
        let callout = try #require(flow.first { $0.kind == .callout })
        let subpageLink = try #require(flow.first { $0.linkedPageId == subpageId })
        let heading = try #require(flow.first { $0.kind == .heading1 })
        let moved = [heading, toggle, columns, callout, subpageLink].map(\.id)
        let undoManager = makeUndoManager()

        undoManager.beginUndoGrouping()
        try tree.moveBlocks(moved, from: pageId, to: target.id)
        undoManager.endUndoGrouping()
        let afterMove = try fingerprint(pageId)
        #expect(afterMove != sourceBefore, "Перенос должен был что-то изменить")
        #expect(try fingerprint(subpageId).page.parentId == target.id)
        #expect(try texts(target.id).contains("Свёрнутый переключатель") && texts(target.id).contains("В колонке"))

        undoManager.undo()

        #expect(try fingerprint(pageId) == sourceBefore)
        #expect(try fingerprint(target.id) == targetBefore)
        #expect(try fingerprint(subpageId) == subpageBefore)
    }

    @Test("Сделать шаблоном → создать по шаблону → перестать быть шаблоном: страница и копия — тот же текст и блоки")
    func templateRoundTrip() throws {
        let (pageId, subpageId) = try richPage()
        let before = try fingerprint(pageId)
        let subpageBefore = try fingerprint(subpageId)

        try tree.makeTemplate(pageId)
        #expect(try fingerprint(pageId).page.isTemplate)
        let copy = try tree.createPage(fromTemplate: pageId)
        try tree.stopBeingTemplate(pageId)

        #expect(try fingerprint(pageId) == before, "Круг «шаблон — не шаблон» исходную не меняет")
        #expect(try fingerprint(subpageId) == subpageBefore)
        let copied = try fingerprint(copy.id)
        #expect(!copied.page.isTemplate)
        #expect(copied.page.title == before.page.title)
        #expect(copied.page.cover == before.page.cover && copied.page.icon == before.page.icon)
        #expect(copied.page.isFullWidth && copied.page.isSmallText)
        #expect(try structure(copy.id) == (try structure(pageId)), "Копия по шаблону — те же блоки и текст")
    }

    @Test("Сделать шаблоном → ⌘Z: страница там же, где была, со ссылкой в родителе; блоки те же")
    func makeTemplateThenUndo() throws {
        let (pageId, subpageId) = try richPage()
        let parent = try store.write { tx in try tx.createPage(title: "Проекты") }
        try tree.move(pageId, toParent: parent.id, at: 0)
        let before = try fingerprint(pageId)
        let parentBefore = try fingerprint(parent.id)
        let subpageBefore = try fingerprint(subpageId)
        let undoManager = makeUndoManager()

        undoManager.beginUndoGrouping()
        try tree.makeTemplate(pageId)
        undoManager.endUndoGrouping()
        undoManager.undo()

        #expect(try fingerprint(pageId) == before)
        #expect(try fingerprint(subpageId) == subpageBefore)
        #expect(try fingerprint(parent.id).blocks.map(\.linkedPageId) == parentBefore.blocks.map(\.linkedPageId), "Ссылка вернулась на место")
    }
}
