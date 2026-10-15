import Foundation
import GRDB
import Testing
@testable import NotesCore

@Suite("Хранилище записей")
struct NotesStoreTests {
    let folder: TemporaryFolder
    let wall = AdjustableWallClock(millis: 1_000)
    let store: NotesStore

    init() throws {
        folder = try TemporaryFolder()
        let clock = HybridLogicalClock(deviceId: UUID(), wallClock: wall.reading)
        store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: clock)
    }

    // MARK: У страницы всегда есть хотя бы один блок

    @Test("Новая страница получает один пустой абзац")
    func newPageHasEmptyParagraph() throws {
        let page = try store.write { try $0.createPage(title: "Заметка") }

        let content = try #require(try store.pageContent(page.id))
        #expect(content.blocks.count == 1)
        #expect(content.blocks.first?.kind == .paragraph)
        #expect(content.blocks.first?.text.string == "")
    }

    @Test("Удалили последний блок — на странице снова пустой абзац")
    func deletingLastBlockLeavesEmptyParagraph() throws {
        let page = try store.write { try $0.createPage(title: "Заметка") }
        let onlyBlock = try #require(try store.pageContent(page.id)?.blocks.first)

        try store.write { try $0.deleteBlock(onlyBlock.id) }

        let blocks = try #require(try store.pageContent(page.id)).blocks
        #expect(blocks.count == 1)
        #expect(blocks.first?.id != onlyBlock.id)
        #expect(blocks.first?.kind == .paragraph)
    }

    @Test("Пустое название показывается как «Без названия»")
    func untitledPageDisplayTitle() throws {
        let page = try store.write { try $0.createPage(title: "") }
        #expect(page.displayTitle == "Без названия")
    }

    @Test("В пути страница — с иконкой перед названием, как у Notion")
    func pathTitleHasIcon() throws {
        var page = try store.write { try $0.createPage(title: "Личный журнал") }
        #expect(page.pathTitle == "Личный журнал")
        page.icon = "🗒️"
        #expect(page.pathTitle == "🗒️ Личный журнал")
    }

    @Test("Дерево читается без текста блоков, по порядку ключей")
    func outlineIsOrderedBySortKey() throws {
        let (first, second, between) = try store.write { tx in
            let first = try tx.createPage(title: "Первая")
            let second = try tx.createPage(title: "Вторая", after: first.sortKey)
            let between = try tx.createPage(title: "Между", after: first.sortKey, before: second.sortKey)
            return (first, second, between)
        }

        #expect(try store.pageOutline().map(\.id) == [first.id, between.id, second.id])
    }

    // MARK: Часы полей

    @Test("Запись страницы ставит новую метку только изменённым полям")
    func pageWriteStampsChangedFieldsOnly() throws {
        let page = try store.write { try $0.createPage(title: "Черновик") }
        let created = page.fieldClocks

        wall.set(5_000)
        var renamed = page
        renamed.title = "Чистовик"
        try store.write { try $0.updatePage(renamed) }

        let stored = try #require(try store.pageContent(page.id)?.page)
        #expect(stored.title == "Чистовик")
        #expect(stored.fieldClocks.title?.wallMillis == 5_000)
        #expect(stored.fieldClocks.icon == created.icon)
        #expect(stored.fieldClocks.placement == created.placement)
        #expect(stored.fieldClocks.trashedAt == created.trashedAt)
    }

    @Test("Запись блока ставит новую метку только изменённым полям")
    func blockWriteStampsChangedFieldsOnly() throws {
        let page = try store.write { try $0.createPage(title: "Заметка") }
        let block = try #require(try store.pageContent(page.id)?.blocks.first)

        wall.set(7_000)
        var edited = block
        edited.text = InlineText("Привет, world", runs: [StyledRun(start: 0, length: 6, style: .bold)])
        try store.write { try $0.updateBlock(edited) }

        let stored = try #require(try store.pageContent(page.id)?.blocks.first)
        #expect(stored.text == edited.text)
        #expect(stored.fieldClocks.text?.wallMillis == 7_000)
        #expect(stored.textBaseClock == stored.fieldClocks.text)
        #expect(stored.fieldClocks.kindAndIndent == block.fieldClocks.kindAndIndent)
        #expect(stored.fieldClocks.isChecked == block.fieldClocks.isChecked)
        #expect(stored.fieldClocks.sortKey == block.fieldClocks.sortKey)
    }

    @Test("Смена типа и отступа — одно поле «тип и отступ»")
    func kindAndIndentShareOneClock() throws {
        let page = try store.write { try $0.createPage(title: "Список") }
        let block = try #require(try store.pageContent(page.id)?.blocks.first)

        wall.set(9_000)
        var item = block
        item.kind = .bulletItem
        item.indent = 2
        try store.write { try $0.updateBlock(item) }

        let stored = try #require(try store.pageContent(page.id)?.blocks.first)
        #expect(stored.kind == .bulletItem && stored.indent == 2)
        #expect(stored.fieldClocks.kindAndIndent?.wallMillis == 9_000)
        #expect(stored.fieldClocks.text == block.fieldClocks.text)
    }

    // MARK: Транзакции

    @Test("Ошибка внутри записи не оставляет половину изменений")
    func failedTransactionLeavesNothing() throws {
        #expect(throws: DeliberateFailure.self) {
            try store.write { tx in
                let page = try tx.createPage(title: "Наполовину")
                var block = try #require(try tx.blocks(ofPage: page.id).first)
                block.text = InlineText("текст")
                try tx.updateBlock(block)
                throw DeliberateFailure()
            }
        }

        #expect(try store.pageOutline().isEmpty)
        let blockCount = try store.database.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM block") }
        #expect(blockCount == 0)
    }

    @Test("Подписчик пишет в ту же транзакцию: его запись появляется вместе с изменением")
    func hookWritesInsideSameTransaction() throws {
        store.addWriteHook(TitleIndexingHook())

        let page = try store.write { try $0.createPage(title: "Индексируемая") }

        let indexed = try store.database.dbWriter.read {
            try String.fetchAll($0, sql: "SELECT content FROM search_index WHERE pageId = ?", arguments: [page.id.uuidString.lowercased()])
        }
        #expect(indexed == ["Индексируемая"])
    }

    @Test("Отказ подписчика отменяет всю запись")
    func failingHookRollsBackWrite() throws {
        store.addWriteHook(FailingHook())

        #expect(throws: DeliberateFailure.self) {
            try store.write { try $0.createPage(title: "Не сохранится") }
        }
        #expect(try store.pageOutline().isEmpty)
    }

    // MARK: Правила модели

    @Test("Блок с нарушенными правилами не записывается")
    func invalidBlocksAreRejected() throws {
        let page = try store.write { try $0.createPage(title: "Правила") }
        let block = try #require(try store.pageContent(page.id)?.blocks.first)

        var tooDeep = block
        tooDeep.kind = .bulletItem
        tooDeep.indent = 9
        var indentedHeading = block
        indentedHeading.kind = .heading2
        indentedHeading.indent = 1
        var checkedParagraph = block
        checkedParagraph.isChecked = true
        var paragraphWithLink = block
        paragraphWithLink.linkedPageId = page.id

        for invalid in [tooDeep, indentedHeading, checkedParagraph, paragraphWithLink] {
            #expect(throws: NotesStoreError.self) { try store.write { try $0.updateBlock(invalid) } }
        }
    }

    @Test("Страница не может быть родителем себе или своему предку")
    func pageCannotBeItsOwnAncestor() throws {
        let (parent, child) = try store.write { tx in
            let parent = try tx.createPage(title: "Родитель")
            let child = try tx.createPage(title: "Ребёнок", parentId: parent.id)
            return (parent, child)
        }

        var selfParent = parent
        selfParent.parentId = parent.id
        var underOwnChild = parent
        underOwnChild.parentId = child.id

        #expect(throws: NotesStoreError.self) { try store.write { try $0.updatePage(selfParent) } }
        #expect(throws: NotesStoreError.self) { try store.write { try $0.updatePage(underOwnChild) } }
    }

    @Test("Иконка — один эмодзи или пусто")
    func iconIsSingleEmoji() throws {
        let page = try store.write { try $0.createPage(title: "Иконка", icon: "📘") }
        #expect(page.icon == "📘")

        var twoSymbols = page
        twoSymbols.icon = "ab"
        #expect(throws: NotesStoreError.self) { try store.write { try $0.updatePage(twoSymbols) } }
    }

    @Test("Id записей — UUID версии 7, упорядочены по времени создания")
    func idsAreTimeOrderedUUIDs() throws {
        let pages = try store.write { tx in try (0..<20).map { try tx.createPage(title: "№\($0)") } }

        for page in pages {
            #expect(page.id.uuidString.lowercased().dropFirst(14).first == "7")
        }
        let ids = pages.map { $0.id.uuidString.lowercased() }
        #expect(ids == ids.sorted())
    }
}

private struct TitleIndexingHook: NotesWriteHook {
    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        for change in changes.pages where change.changedFields.contains(.title) {
            try transaction.execute(
                sql: "INSERT INTO search_index(pageId, blockId, content) VALUES (?, NULL, ?)",
                arguments: [.text(change.page.id.uuidString.lowercased()), .text(change.page.title)]
            )
        }
    }
}

private struct FailingHook: NotesWriteHook {
    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        throw DeliberateFailure()
    }
}
