import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Смена типа в фоне (SC-305, по образцу R21): чтение и перевод — вне записи, запись — пачками, правки с главного потока
/// проходят между пачками и не затираются, ⌘Z — один шаг (тоже в фоне).
@MainActor
@Suite("Смена типа в фоне")
struct BackgroundTypeChangeTests {
    static let rowCount = 3_000
    let store: NotesStore
    let undo = UndoManager()
    let operations: DatabaseOperations
    let base: CreatedDatabase
    let hours: DatabaseProperty
    let note: DatabaseProperty
    let rows: [UUID]

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bgtype-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        let quiet = DatabaseOperations(store: store)
        base = try quiet.createDatabase(in: nil, isInline: false, title: "Задачи")
        hours = try quiet.addProperty(to: base.databaseId, name: "Часы", kind: .number)
        note = try quiet.addProperty(to: base.databaseId, name: "Заметка", kind: .text)
        let (databaseId, hoursId) = (base.databaseId, hours.id)
        rows = try store.write { tx throws in
            try (0..<Self.rowCount).map { index in
                let page = try tx.createPage(title: "Задача \(index)", parentId: databaseId)
                try tx.setCell(rowId: page.id, propertyId: hoursId, value: .number(Double(index % 40)))
                return page.id
            }
        }
        undo.groupsByEvent = false
        operations = DatabaseOperations(store: store, undoManager: undo)
    }

    func value(_ row: UUID, _ property: UUID) throws -> JSONValue? {
        try store.write { try $0.cell(rowId: row, propertyId: property)?.value }
    }

    func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try body()
        let took = ContinuousClock.now - start
        return Double(took.components.seconds) * 1_000 + Double(took.components.attoseconds) / 1e15
    }

    @Test("Число → текст: главный поток свободен, правки во время перевода проходят и остаются; ⌘Z — один шаг")
    func numberToTextInBackground() async throws {
        var task: Task<Void, any Error>!
        let start = milliseconds { task = operations.startChangeType(hours.id, to: .text) }
        #expect(start <= 100, "запуск занял \(start) мс")

        // Пока идёт перевод: правки с главного потока — каждая не дольше 100 мс; одна — в само переводимое свойство.
        var edits: [Double] = []
        let editor = DatabaseOperations(store: store)
        for index in 0..<15 {
            edits.append(try milliseconds { try editor.setCell(rowId: rows[index], propertyId: note.id, value: ["runs": [], "string": "правка"]) })
            try await Task.sleep(for: .milliseconds(5))
        }
        try await task.value
        #expect(edits.max() ?? 0 <= 100, "правки ждали: \(edits)")
        #expect(try store.write { try $0.property(hours.id)?.kind } == .text)
        #expect(try value(rows[7], hours.id) == ["runs": [], "string": "7"])
        #expect(try value(rows[2_999], hours.id) == ["runs": [], "string": "39"])
        #expect(try value(rows[3], note.id)?["string"]?.string == "правка", "правка другой колонки во время перевода на месте")

        #expect(undo.canUndo)
        undo.undo()
        try await operations.pendingRewrite?.value
        #expect(try store.write { try $0.property(hours.id)?.kind } == .number)
        #expect(try value(rows[7], hours.id) == .number(7))
        #expect(try value(rows[2_999], hours.id) == .number(39))
        #expect(undo.canRedo, "⇧⌘Z есть")
        undo.redo()
        try await operations.pendingRewrite?.value
        #expect(try value(rows[7], hours.id) == ["runs": [], "string": "7"])
    }

    @Test("Ячейку переводимого свойства поправили после чтения — пачка её не затирает")
    func editDuringRewriteSurvives() async throws {
        let task = operations.startChangeType(hours.id, to: .text, beforeWriting: { [store, rows, hours] in
            // Между чтением и записью: правка уже в новом типе (как с главного потока сразу после смены типа).
            _ = try store.write { tx throws in try tx.setCell(rowId: rows[5], propertyId: hours.id, value: ["runs": [], "string": "своё"]) }
        })
        try await task.value
        #expect(try value(rows[5], hours.id) == ["runs": [], "string": "своё"])
        #expect(try value(rows[6], hours.id) == ["runs": [], "string": "6"])
    }
}
