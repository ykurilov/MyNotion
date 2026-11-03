import Foundation
import Testing
@testable import Databases
@testable import NotesCore
@testable import PageSearch

/// Поиск по строкам баз (T100, spec US1, research R14): строка находится по названию, тексту страницы и текстовому
/// значению свойства; путь — до базы через её родителей; шаблоны строк, строки в корзине и строки базы в корзине
/// не находятся. Дерево — как у приложения (`pageTree`): строк в нём нет.
@MainActor
@Suite("Поиск: строки баз")
struct PageSearchDatabaseTests {
    let library: SearchLibrary
    let databases: DatabaseOperations
    let parent: Page
    let tasks: CreatedDatabase
    let note: DatabaseProperty
    let status: DatabaseProperty
    let row: UUID

    init() throws {
        library = try SearchLibrary()
        library.store.addWriteHook(CellIndexer())
        databases = DatabaseOperations(store: library.store)
        parent = try library.page("Проекты")
        tasks = try databases.createDatabase(in: parent.id, isInline: false, title: "Задачи")
        note = try databases.addProperty(to: tasks.databaseId, name: "Заметка", kind: .text)
        status = try databases.addProperty(to: tasks.databaseId, name: "Статус", kind: .select)
        row = try databases.addRow(to: tasks.databaseId, in: nil, title: "Позвонить сантехнику")
    }

    private func search(_ query: String) throws -> [PageSearchResult] {
        try PageSearch(store: library.store).results(for: query, in: library.store.pageTree())
    }

    private func found(_ query: String) throws -> [UUID] { try search(query).map(\.pageId) }

    private func addText(_ text: String, to pageId: UUID) throws {
        try library.store.write { tx in
            let last = try tx.blocks(ofPage: pageId).last?.sortKey
            try tx.insertBlock(Block(pageId: pageId, text: InlineText(text), sortKey: .between(last, nil)))
        }
    }

    @Test("Строка находится по названию; путь — родитель базы и база")
    func rowByTitle() throws {
        let result = try #require(try search("сантехник").first)
        #expect(result.pageId == row)
        #expect(result.title == "Позвонить сантехнику")
        #expect(result.path == ["Проекты", "Задачи"])
    }

    @Test("Строка находится по тексту своей страницы; страница внутри строки — с путём через строку")
    func rowByBody() throws {
        try addText("Кран на кухне течёт", to: row)
        let result = try #require(try search("кран").first)
        #expect(result.pageId == row)
        #expect(result.snippet?.text.contains("Кран") == true)
        #expect(result.blockId != nil)

        let inner = try library.page("Список инструментов", parent: row)
        let innerResult = try #require(try search("инструментов").first)
        #expect(innerResult.pageId == inner.id)
        #expect(innerResult.path == ["Проекты", "Задачи", "Позвонить сантехнику"])
    }

    @Test("Строка находится по текстовому значению и по варианту выбора; кусок текста — значение")
    func rowByCellValue() throws {
        try databases.setCell(rowId: row, propertyId: note.id, value: ["runs": [], "string": "уточнить адрес квартиры"])
        _ = try databases.pickOption(named: "Срочно", rowId: row, propertyId: status.id)

        let byText = try #require(try search("квартиры").first)
        #expect(byText.pageId == row)
        #expect(byText.snippet?.text.contains("квартиры") == true)
        #expect(byText.blockId == nil)
        #expect(byText.path == ["Проекты", "Задачи"])

        #expect(try found("срочно") == [row])
    }

    @Test("Строки встроенной базы находятся с путём через страницу, где стоит база")
    func inlineDatabaseRow() throws {
        let page = try library.page("Дневник")
        let inline = try databases.createDatabase(in: page.id, isInline: true, title: "Покупки")
        let item = try databases.addRow(to: inline.databaseId, in: nil, title: "Молоко")
        let result = try #require(try search("молоко").first)
        #expect(result.pageId == item)
        #expect(result.path == ["Дневник", "Покупки"])
    }

    @Test("Шаблоны строк и всё внутри них не находятся")
    func templatesHidden() throws {
        let template = try databases.addRow(to: tasks.databaseId, in: nil, title: "Шаблон звонка")
        try library.store.write { tx in
            var page = try #require(try tx.page(template))
            page.isTemplate = true
            try tx.updatePage(page)
        }
        try addText("Заготовка звонка", to: template)
        try library.page("Подстраница звонка", parent: template)
        #expect(try found("звонка").isEmpty)
    }

    @Test("Строки в корзине и строки базы в корзине не находятся")
    func trashHidden() throws {
        let other = try databases.addRow(to: tasks.databaseId, in: nil, title: "Сантехник второй")
        try databases.trashRows([other])
        #expect(try found("сантехник") == [row])

        try PageTreeOperations(store: library.store).moveToTrash(tasks.databaseId)
        #expect(try found("сантехник").isEmpty)
    }
}
