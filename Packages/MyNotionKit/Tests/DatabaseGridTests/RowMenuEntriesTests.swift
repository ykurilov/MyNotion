import AppKit
import Foundation
import Testing
import VisualStyle
@testable import DatabaseGrid
@testable import Databases
@testable import NotesCore

/// Меню строки (contracts/database-ui.md, «Строки»): «Изменить иконку» при обработчике окна и подпись внизу с числом слов.
@MainActor
@Suite("Меню строки: иконка и подпись")
struct RowMenuEntriesTests {
    let store: NotesStore
    let grid: DatabaseGridView
    let controller: DatabaseTableController

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rowmenu-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        let operations = DatabaseOperations(store: store)
        let base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        try operations.addRow(to: base.databaseId, in: base.viewId, title: "Купить хлеб молоко")
        controller = try #require(DatabaseTableController(store: store, operations: operations, databaseId: base.databaseId))
        grid = DatabaseGridView(controller: controller, scrollsVertically: false)
    }

    private func titles(_ actions: RowMenuActions) -> [String] {
        let entries = RowMenuPresenter.entries(rowId: controller.content.rowId(at: 0)!, rows: [0], grid: grid, controller: controller,
                                               actions: actions, submenu: { _, _ in })
        return entries.compactMap {
            switch $0 {
            case .action(let action): action.title
            case .footer(let text, _): text
            default: nil
            }
        }
    }

    @Test("«Изменить иконку» стоит после «В избранное», когда окно умеет менять иконку; без обработчика пункта нет")
    func changeIconItem() {
        var actions = RowMenuActions()
        actions.toggleFavorite = { _ in }
        #expect(!titles(actions).contains("Изменить иконку"))
        actions.changeIcon = { _, _ in }
        let items = titles(actions)
        #expect(Array(items.prefix(2)) == ["В избранное", "Изменить иконку"])
    }

    @Test("Подпись внизу: «Изменено …, N слов» — слова названия строки")
    func footerHasWordCount() throws {
        let footer = try #require(titles(RowMenuActions()).last)
        #expect(footer.hasPrefix("Изменено "))
        #expect(footer.hasSuffix(", 3 слова"), "подпись: \(footer)")
    }

    @Test("Слова по-русски: 1 слово, 2 слова, 5 слов, 11 слов, 21 слово")
    func wordForms() {
        #expect([1, 2, 5, 11, 21, 0].map(RowMenuFooter.words) == ["1 слово", "2 слова", "5 слов", "11 слов", "21 слово", "0 слов"])
    }
}
