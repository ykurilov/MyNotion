import AppKit
import Foundation
import Testing
import VisualStyle
@testable import DatabaseRowPage
@testable import Databases
@testable import NotesCore

/// Вид свойств строки: высота, щелчок по флажку, поле на месте (запись только изменённого), окно правки у выбора,
/// без правки у ID; новое чтение ждёт конца правки.
@MainActor
@Suite("Страница строки: вид свойств")
struct RowPropertiesViewTests {
    let store: NotesStore
    let operations: DatabaseOperations
    let database: CreatedDatabase
    let rowId: UUID
    let number: DatabaseProperty
    let done: DatabaseProperty
    let choice: DatabaseProperty
    let id: DatabaseProperty

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rowview-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        operations = DatabaseOperations(store: store)
        database = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        rowId = try operations.addRow(to: database.databaseId, in: database.viewId, title: "Купить молоко")
        number = try operations.addProperty(to: database.databaseId, name: "Число", kind: .number)
        done = try operations.addProperty(to: database.databaseId, name: "Готово", kind: .checkbox)
        choice = try operations.addProperty(to: database.databaseId, name: "Выбор", kind: .select)
        id = try operations.addProperty(to: database.databaseId, name: "ID", kind: .uniqueId)
    }

    private func makeView() throws -> (RowPropertiesView, [(UUID, JSONValue?)]) {
        let view = RowPropertiesView(page: try #require(try RowPage.read(rowId, in: store)))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: view.fittingHeight)
        view.layoutSubtreeIfNeeded()
        return (view, [])
    }

    @Test("Высота: строка на свойство и «+ Добавить свойство»")
    func height() throws {
        let (view, _) = try makeView()
        let metrics = Metrics.RowPage.self
        #expect(view.fittingHeight == metrics.topPadding + 5 * metrics.lineHeight + metrics.bottomPadding)
        #expect(view.lineView(for: number.id)?.frame.minY == metrics.topPadding)
    }

    @Test("Флажок — запись по щелчку; выбор — окно правки; ID — ничего")
    func pressValue() throws {
        let (view, _) = try makeView()
        var commits: [(UUID, JSONValue?)] = []
        var opened: [UUID] = []
        view.onCommit = { commits.append(($0, $1)) }
        view.onOpenEditor = { propertyId, _ in opened.append(propertyId) }
        view.lineView(for: done.id)?.pressValue()
        view.lineView(for: choice.id)?.pressValue()
        view.lineView(for: id.id)?.pressValue()
        #expect(commits.count == 1 && commits.first?.0 == done.id && commits.first?.1 == .bool(true))
        #expect(opened == [choice.id])
    }

    @Test("Поле: Enter пишет набранное; без изменений — не пишет; чтение во время правки ждёт её конца")
    func field() throws {
        let (view, _) = try makeView()
        var commits: [(UUID, JSONValue?)] = []
        view.onCommit = { commits.append(($0, $1)) }
        let line = try #require(view.lineView(for: number.id))
        line.pressValue()
        #expect(line.isEditing)
        line.finishEditing()
        #expect(commits.isEmpty, "ничего не набрали")

        line.pressValue()
        let editor = try #require(line.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
        editor.stringValue = "42"
        // Пока поле открыто, новое значение с другого Mac не пересобирает строки.
        try operations.setCell(rowId: rowId, propertyId: done.id, value: .bool(true))
        view.show(try #require(try RowPage.read(rowId, in: store)))
        #expect(view.page.row.cells[done.id] == nil)
        line.finishEditing()
        #expect(commits.count == 1 && commits[0].0 == number.id && commits[0].1 == .number(42))
        #expect(view.page.row.cells[done.id] == .bool(true))
    }
}
