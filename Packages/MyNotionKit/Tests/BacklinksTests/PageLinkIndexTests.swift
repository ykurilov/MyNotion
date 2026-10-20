import Foundation
import GRDB
import Testing
@testable import Backlinks
@testable import NotesCore

/// Подписчик записи держит `page_link` в согласии с блоками (research R10, tasks.md T067).
@Suite("Индекс обратных ссылок")
struct PageLinkIndexTests {
    @Test("Упоминание страницы — строка индекса в той же транзакции, что блок")
    func mentionWritesRow() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let source = try library.page("А")
        let block = try library.addMention(of: target.id, on: source.id)
        #expect(try library.rows() == ["\(block.id.databaseText)>\(target.id.databaseText)@\(source.id.databaseText)"])
    }

    @Test("Ссылка-подстраница на чужую страницу — строка; на своего ребёнка — строки нет")
    func pageLinkToForeignAndToChild() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let parent = try library.page("Родитель")
        let child = try library.page("Ребёнок", parent: parent.id)
        let toChild = try library.addPageLink(to: child.id, on: parent.id)
        #expect(try library.rowCount(target: child.id) == 0)
        let foreign = try library.addPageLink(to: target.id, on: parent.id)
        #expect(try library.rows() == ["\(foreign.id.databaseText)>\(target.id.databaseText)@\(parent.id.databaseText)"])
        #expect(try library.store.write { try $0.block(toChild.id) } != nil)
    }

    @Test("Упоминание ребёнка на странице родителя — обычная обратная ссылка")
    func mentionOfChildCounts() throws {
        let library = try BacklinksLibrary()
        let parent = try library.page("Родитель")
        let child = try library.page("Ребёнок", parent: parent.id)
        try library.addMention(of: child.id, on: parent.id)
        #expect(try library.rowCount(target: child.id) == 1)
    }

    @Test("Ссылка на ребёнка записана раньше, чем появилась страница ребёнка, — когда страница появилась, строка уходит")
    func linkBeforeChildPage() throws {
        let library = try BacklinksLibrary()
        let parent = try library.page("Родитель")
        let childId = UUID.timeOrdered()
        try library.store.write { transaction in
            try transaction.insertBlock(Block(pageId: parent.id, kind: .pageLink, linkedPageId: childId, sortKey: .between(nil, nil)))
        }
        #expect(try library.rowCount(target: childId) == 1)
        try library.store.write { transaction in
            var child = Page(id: childId, title: "Ребёнок", parentId: parent.id, sortKey: .between(nil, nil), createdAt: Date(), updatedAt: Date())
            try transaction.insertPage(&child)
        }
        #expect(try library.rowCount(target: childId) == 0)
    }

    @Test("Правка блока: упоминание заменено другим — старая строка ушла, новая встала")
    func editReplacesRows() throws {
        let library = try BacklinksLibrary()
        let first = try library.page("Б")
        let second = try library.page("В")
        let source = try library.page("А")
        let block = try library.addMention(of: first.id, on: source.id)
        try library.store.write { transaction in
            var changed = try #require(try transaction.block(block.id))
            changed.text = BacklinksLibrary.text("Теперь ", mentioning: second.id)
            try transaction.updateBlock(changed)
        }
        #expect(try library.rowCount(target: first.id) == 0)
        #expect(try library.rowCount(target: second.id) == 1)
    }

    @Test("Блок с двумя упоминаниями одной страницы — одна строка; с двумя разными — две")
    func severalMentionsInBlock() throws {
        let library = try BacklinksLibrary()
        let first = try library.page("Б")
        let second = try library.page("В")
        let source = try library.page("А")
        try library.store.write { transaction in
            let text = InlineText("\u{FFFC}\u{FFFC}\u{FFFC}", runs: [
                StyledRun(start: 0, length: 1, style: .mention(first.id)),
                StyledRun(start: 1, length: 1, style: .mention(first.id)),
                StyledRun(start: 2, length: 1, style: .mention(second.id)),
            ])
            try transaction.insertBlock(Block(pageId: source.id, text: text, sortKey: .between(nil, nil)))
        }
        #expect(try library.rowCount(target: first.id) == 1)
        #expect(try library.rowCount(target: second.id) == 1)
    }

    @Test("Стёртое упоминание и удалённый блок убирают строки")
    func eraseMentionAndDeleteBlock() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let source = try library.page("А")
        let first = try library.addMention(of: target.id, on: source.id)
        let second = try library.addMention(of: target.id, on: source.id)
        try library.eraseMention(in: first)
        #expect(try library.rowCount(target: target.id) == 1)
        try library.deleteBlock(second.id)
        #expect(try library.rows().isEmpty)
    }

    @Test("Страница стёрта навсегда — её строки (источника и цели) уходят")
    func erasedPageDropsRows() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let source = try library.page("А")
        try library.addMention(of: target.id, on: source.id)
        try library.addMention(of: source.id, on: target.id)
        try library.store.write { try $0.erasePage(source.id) }
        #expect(try library.rows().isEmpty)
    }

    @Test("Пачка с другого Mac: блок, пришедший репликой, и его удаление")
    func replicatedBlock() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let source = try library.page("А")
        let incoming = Block(pageId: source.id, text: BacklinksLibrary.text("С другого Mac ", mentioning: target.id), sortKey: .between(nil, nil))
        try library.store.write { transaction in
            try transaction.writeReplicatedBlock(incoming, isDeleted: false, changedFields: Set(Block.Field.allCases))
        }
        #expect(try library.rowCount(target: target.id) == 1)
        try library.store.write { transaction in
            try transaction.writeReplicatedBlock(incoming, isDeleted: true, changedFields: [.deleted])
        }
        #expect(try library.rowCount(target: target.id) == 0)
    }

    @Test("Импорт: много блоков одной записью — по строке на каждое упоминание")
    func bulkImport() throws {
        let library = try BacklinksLibrary()
        let target = try library.page("Б")
        let source = try library.page("А")
        try library.store.write { transaction in
            var previous: FractionalSortKey?
            for index in 0..<50 {
                let key = FractionalSortKey.between(previous, nil)
                let text = index.isMultiple(of: 2) ? BacklinksLibrary.text("Упоминание \(index) ", mentioning: target.id) : InlineText("Без ссылок \(index)")
                try transaction.insertBlock(Block(pageId: source.id, text: text, sortKey: key))
                previous = key
            }
        }
        #expect(try library.rowCount(target: target.id) == 25)
    }

    @Test("Набор текста без ссылок строк не создаёт")
    func plainTypingWritesNothing() throws {
        let library = try BacklinksLibrary()
        let source = try library.page("А")
        try library.store.write { transaction in
            var block = try #require(try transaction.blocks(ofPage: source.id).first)
            block.text = InlineText("обычный текст")
            try transaction.updateBlock(block)
        }
        #expect(try library.rows().isEmpty)
    }

    @Test("Первое заполнение: по всем блокам один раз, потом отметка в app_meta")
    func firstFill() async throws {
        let library = try BacklinksLibrary(indexBuilt: false)
        let target = try library.page("Б")
        let source = try library.page("А")
        let mention = try library.addMention(of: target.id, on: source.id)
        let link = try library.addPageLink(to: target.id, on: source.id)
        // База «до 003»: строк ещё нет.
        try library.clearRows()
        #expect(try library.backlinks.count(of: target.id) == 0)

        try await BacklinkIndexBuild(store: library.store).runIfNeeded()
        #expect(try library.store.appMeta(BacklinkIndexBuild.builtKey) != nil)
        #expect(try library.rowCount(target: target.id) == 2)
        #expect(try library.backlinks.count(of: target.id) == 1)

        // Второй раз ничего не строится: удалённая строка не возвращается.
        try library.clearRows()
        try await BacklinkIndexBuild(store: library.store).runIfNeeded()
        #expect(try library.rows().isEmpty)
        _ = (mention, link)
    }

    @Test("Заполнение не затирает новее записанное и не берёт удалённые блоки")
    func firstFillSkipsDeletedBlocks() async throws {
        let library = try BacklinksLibrary(indexBuilt: false)
        let target = try library.page("Б")
        let source = try library.page("А")
        let kept = try library.addMention(of: target.id, on: source.id)
        let removed = try library.addMention(of: target.id, on: source.id)
        try library.deleteBlock(removed.id)
        try library.clearRows()
        try await BacklinkIndexBuild(store: library.store, batchSize: 1).runIfNeeded()
        #expect(try library.rows() == ["\(kept.id.databaseText)>\(target.id.databaseText)@\(source.id.databaseText)"])
    }

    @Test("Заполнение не строит ссылку родителя на своего ребёнка")
    func firstFillSkipsParentToChild() async throws {
        let library = try BacklinksLibrary(indexBuilt: false)
        let parent = try library.page("Родитель")
        let child = try library.page("Ребёнок", parent: parent.id)
        try library.addPageLink(to: child.id, on: parent.id)
        try library.clearRows()
        try await BacklinkIndexBuild(store: library.store).runIfNeeded()
        #expect(try library.rows().isEmpty)
    }
}
