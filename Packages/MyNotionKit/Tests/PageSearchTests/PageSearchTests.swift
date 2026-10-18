import Foundation
import GRDB
import Testing
@testable import NotesCore
@testable import PageSearch

@Suite("Поиск страниц по слову (US4, FR-018)")
struct PageSearchTests {
    let library: SearchLibrary

    init() throws {
        library = try SearchLibrary()
    }

    @Test("Название ищется по началу слова")
    func titleByWordPrefix() throws {
        let page = try library.page("Рецепты пирогов")
        try library.page("Список дел")

        #expect(try library.foundPageIds("пир") == [page.id])
        #expect(try library.foundPageIds("ецепт").isEmpty)
    }

    @Test("Текст блоков ищется по началу слова, кириллица и латиница, регистр не важен")
    func blockTextByPrefixAnyCase() throws {
        let milk = try library.page("Покупки", blocks: ["Купить молоко завтра"])
        let swift = try library.page("Заметки", blocks: ["Учу SwiftUI и AppKit"])

        #expect(try library.foundPageIds("молок") == [milk.id])
        #expect(try library.foundPageIds("МОЛОКО") == [milk.id])
        #expect(try library.foundPageIds("swift") == [swift.id])
        #expect(try library.foundPageIds("APPK") == [swift.id])
    }

    @Test("«ё» и «е» — одна буква в тексте и в запросе")
    func yoEqualsYe() throws {
        let tree = try library.page("Ёлка", blocks: ["Зелёная и пушистая"])
        let hedgehog = try library.page("Еж", blocks: [])

        #expect(try library.foundPageIds("елк") == [tree.id])
        #expect(try library.foundPageIds("зеле") == [tree.id])
        #expect(try library.foundPageIds("зелё") == [tree.id])
        #expect(try library.foundPageIds("ёж") == [hedgehog.id])
    }

    @Test("Несколько слов: страница, где есть все, каждое — по началу")
    func severalWords() throws {
        let both = try library.page("План", blocks: ["Позвонить маме вечером"])
        try library.page("Другое", blocks: ["Позвонить врачу"])

        #expect(try library.foundPageIds("позв веч") == [both.id])
    }

    @Test("Сначала совпадения в названии, потом в тексте")
    func titleMatchesComeFirst() throws {
        let inText = try library.page("Дневник", blocks: ["Сегодня кот спал весь день"])
        let inTitle = try library.page("Кот Барсик")

        let results = try library.search("кот")
        #expect(results.map(\.pageId) == [inTitle.id, inText.id])
        #expect(results[0].snippet == nil)
        #expect(results[1].snippet != nil)
    }

    @Test("Страница с совпадением и в названии, и в тексте — одна строка выдачи")
    func onePageOneResult() throws {
        let page = try library.page("Кот", blocks: ["Кот спит", "Кот ест"])

        #expect(try library.foundPageIds("кот") == [page.id])
    }

    @Test("Страницы в корзине из выдачи исключаются — вместе с подстраницами")
    @MainActor
    func trashIsExcluded() throws {
        let parent = try library.page("Проект ракета", blocks: ["ракета летит"])
        let child = try library.page("Двигатель ракеты", parent: parent.id)
        let kept = try library.page("Ракетка для тенниса")

        try PageTreeOperations(store: library.store).moveToTrash(parent.id)

        #expect(try library.foundPageIds("ракет") == [kept.id])

        try PageTreeOperations(store: library.store).restore(parent.id)
        #expect(Set(try library.foundPageIds("ракет")) == [parent.id, child.id, kept.id])
    }

    @Test("Правка текста и названия сразу меняет выдачу: старое слово больше не находится")
    @MainActor
    func editsUpdateIndex() throws {
        let page = try library.page("Черновик", blocks: ["старое слово"])
        var block = try #require(try library.store.pageContent(page.id)?.blocks.first)

        block.text = InlineText("новое слово")
        try library.store.write { try $0.updateBlock(block) }
        try PageTreeOperations(store: library.store).rename(page.id, to: "Чистовик")

        #expect(try library.foundPageIds("стар").isEmpty)
        #expect(try library.foundPageIds("нов") == [page.id])
        #expect(try library.foundPageIds("черн").isEmpty)
        #expect(try library.foundPageIds("чист") == [page.id])
    }

    @Test("Удалённый блок и стёртая навсегда страница не находятся")
    func deletedBlocksAndErasedPages() throws {
        let page = try library.page("Страница", blocks: ["первый абзац", "второй абзац"])
        let second = try #require(try library.store.pageContent(page.id)?.blocks.last)
        try library.store.write { try $0.deleteBlock(second.id) }
        #expect(try library.foundPageIds("втор").isEmpty)
        #expect(try library.foundPageIds("перв") == [page.id])

        let erased = try library.page("Стираемая", blocks: ["уникальноеслово"])
        try library.store.write { try $0.erasePage(erased.id) }
        let leftovers = try library.indexRowCount(ofPage: erased.id)
        #expect(leftovers == 0)
    }

    @Test("Индекс обновлён в той же транзакции: отменённая запись не оставляет следа в поиске")
    func indexIsWrittenInsideTheSameTransaction() throws {
        let page = try library.page("Транзакция")
        var block = try #require(try library.store.pageContent(page.id)?.blocks.first)
        block.text = InlineText("откатываемое")

        #expect(throws: DeliberateFailure.self) {
            try library.store.write { transaction in
                try transaction.updateBlock(block)
                throw DeliberateFailure()
            }
        }
        #expect(try library.foundPageIds("откат").isEmpty)

        // Запись видна поиску сразу после `write`, без ожидания.
        try library.store.write { try $0.updateBlock(block) }
        #expect(try library.foundPageIds("откат") == [page.id])
    }

    @Test("У результата — иконка, путь родителей и кусок текста с найденным словом")
    func resultShowsPathAndSnippet() throws {
        let root = try library.page("Работа", icon: "💼")
        let parent = try library.page("Клиенты", parent: root.id)
        let child = try library.page("Встреча", icon: "📅", parent: parent.id,
                                     blocks: ["Обсудили бюджет на следующий квартал и сроки"])

        let result = try #require(try library.search("бюдж").first)
        #expect(result.pageId == child.id)
        #expect(result.title == "Встреча")
        #expect(result.icon == "📅")
        #expect(result.path == ["Работа", "Клиенты"])
        let snippet = try #require(result.snippet)
        let highlighted = snippet.highlights.map { (snippet.text as NSString).substring(with: $0) }
        #expect(highlighted == ["бюдж"])
    }

    @Test("Кусок длинного текста начинается недалеко от найденного слова")
    func longTextSnippetIsCentered() throws {
        let filler = Array(repeating: "слово", count: 60).joined(separator: " ")
        try library.page("Длинная", blocks: ["\(filler) иголка \(filler)"])

        let snippet = try #require(try library.search("игол").first?.snippet)
        #expect(snippet.text.count <= PageSearch.snippetLength + 2)
        #expect(snippet.text.hasPrefix("…"))
        let highlighted = snippet.highlights.map { (snippet.text as NSString).substring(with: $0) }
        #expect(highlighted == ["игол"])
    }

    @Test("Совпадение в названии подсвечено в названии")
    func titleHighlight() throws {
        try library.page("Большой план")

        let result = try #require(try library.search("пла").first)
        #expect(result.titleHighlights.map { (result.title as NSString).substring(with: $0) } == ["пла"])
    }

    @Test("Пустой запрос и запрос из одних знаков ничего не ищут")
    func emptyQuery() throws {
        try library.page("Что-то")

        #expect(try library.search("").isEmpty)
        #expect(try library.search("  ").isEmpty)
        #expect(try library.search("\"*()").isEmpty)
    }

    @Test("Знаки FTS в запросе не ломают поиск")
    func queryWithOperatorsIsSafe() throws {
        let page = try library.page("Заметка", blocks: ["NOT AND OR near"])

        #expect(try library.foundPageIds("not") == [page.id])
        #expect(try library.foundPageIds("\"near") == [page.id])
    }

    @Test("Выдача ограничена: длинный список не строится целиком")
    func resultsAreLimited() throws {
        try library.store.write { transaction in
            for number in 0..<(PageSearch.defaultLimit + 10) {
                try transaction.createPage(title: "Отчёт \(number)")
            }
        }

        #expect(try library.search("отч").count == PageSearch.defaultLimit)
    }
}

@Suite("Наполнение индекса для старых баз")
struct SearchIndexMigrationTests {
    @Test("База без индекса после миграции находит старые записи; перед миграцией сделана копия")
    func migrationFillsIndexForExistingLibrary() throws {
        let folder = try TemporaryFolder()
        let clock = HybridLogicalClock(deviceId: UUID())
        let beforeSearch = SchemaMigrations(steps: Array(SchemaMigrations.current.steps.dropLast()))

        let old = try AppDatabase.open(at: folder.databaseURL, migrations: beforeSearch)
        let page = try NotesStore(database: old, clock: clock).write { transaction in
            let page = try transaction.createPage(title: "Старая ёлка")
            var block = try #require(try transaction.blocks(ofPage: page.id).first)
            block.text = InlineText("Записано до поиска")
            try transaction.updateBlock(block)
            return page
        }
        let versionBefore = try #require(try old.appliedSchemaVersion())
        old.close()

        let migrated = try AppDatabase.open(at: folder.databaseURL)
        defer { migrated.close() }
        let library = SearchLibrary(store: NotesStore(database: migrated, clock: clock))
        #expect(try library.foundPageIds("елк") == [page.id])
        #expect(try library.foundPageIds("записано") == [page.id])
        let backup = AppDatabase.backupURL(for: folder.databaseURL, version: versionBefore)
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }

    @Test("Наполнение миграцией и подписчик пишут индекс одинаково")
    func migrationMatchesIndexer() throws {
        let indexed = try SearchLibrary()
        let page = try indexed.page("Ёжик Ё", blocks: ["Зелёный ЁЖ"])
        let rowsFromIndexer = try indexed.indexRows()

        try indexed.store.database.dbWriter.write { try SchemaMigrations.fillSearchIndex($0) }

        #expect(try indexed.indexRows() == rowsFromIndexer)
        #expect(try indexed.foundPageIds("ежик") == [page.id])
    }
}
