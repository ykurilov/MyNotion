import Foundation
import Testing
@testable import Databases
@testable import NotesCore
@testable import Sync

/// Совпавшие номера ID после синхронизации (T103, research R9): строка, созданная позже, получает следующий свободный
/// номер обычной правкой ячейки; починка на двух Mac сразу сходится.
@MainActor
@Suite("Починка номеров ID")
struct UniqueIdRepairTests {
    let numbering = TestJournalNumbering()
    let a: SyncTestMac
    let b: SyncTestMac

    init() throws {
        a = try SyncTestMac(name: "Mac A", wallMillis: 10_000)
        b = try SyncTestMac(name: "Mac B", wallMillis: 10_000)
        for mac in [a, b] { mac.store.addWriteHook(CellIndexer()) }
    }

    @Test("Две строки без связи получили один номер — после встречи номера разные и одинаковые на обоих Mac")
    func offlineRowsGetDistinctNumbers() throws {
        let db = try makeTasksDatabase(on: a)
        let idProperty = try a.store.write { tx in
            try tx.saveProperty(DatabaseProperty(databaseId: db.database, name: "Номер", kind: .uniqueId, config: .emptyObject,
                                                 sortKey: .between(nil, nil))).id
        }
        try exchange([a, b], numbering: numbering)

        func addRow(on mac: SyncTestMac, _ title: String) throws -> UUID {
            try mac.store.write { tx in
                let row = try tx.createPage(title: title, parentId: db.database).id
                try tx.setCell(rowId: row, propertyId: idProperty, value: .number(Double(try UniqueIds.nextNumber(of: idProperty, in: tx))))
                return row
            }
        }
        let fromA = try addRow(on: a, "Записано на A")
        let fromB = try addRow(on: b, "Записано на B")
        try exchange([a, b], numbering: numbering)
        func numbers(_ mac: SyncTestMac) throws -> [Double?] {
            try mac.store.write { tx in try [fromA, fromB].map { try tx.cell(rowId: $0, propertyId: idProperty)?.value?.number } }
        }
        #expect(try numbers(a) == [1, 1], "без починки номера совпадают")

        for mac in [a, b] { try DatabaseOperations.repairDuplicateIds(in: mac.store) }
        try exchange([a, b], numbering: numbering)

        #expect(try numbers(a) == [1, 2], "раньше созданная строка сохраняет номер")
        #expect(try numbers(b) == numbers(a))
        for mac in [a, b] { #expect(try DatabaseOperations.repairDuplicateIds(in: mac.store).isEmpty) }
    }
}
