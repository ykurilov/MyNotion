import Foundation
import GRDB
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Запись вычисленных значений")
struct ComputedWriterTests {
    @Test("Неизменный кэш не переписывается; значения, live и сравнимые колонки обновляются")
    func changedAndUnchangedValues() throws {
        let queue = try DatabaseQueue()
        try SchemaMigrations.current.migrator.migrate(queue)
        let row = UUID(), property = UUID()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO page(id, title, sortKey, createdAt, updatedAt, fieldClocks)
                VALUES (?, 'Строка', 'a', 1, 2, '{}')
                """, arguments: [row.databaseText])
            let pageBefore = try Row.fetchOne(db, sql: "SELECT * FROM page WHERE id = ?", arguments: [row.databaseText])
            let outboxBefore = try Int.fetchOne(db, sql: "SELECT count(*) FROM outbox_entry")
            var value = ComputedValue(rowId: row, propertyId: property, value: .number(12.5))
            try ComputedWriter.write([value], in: db)
            #expect(db.changesCount == 1)
            try ComputedWriter.write([value], in: db)
            #expect(db.changesCount == 0)
            value.isLive = true
            try ComputedWriter.write([value], in: db)
            #expect(db.changesCount == 1, "live меняется и при прежнем значении")
            #expect(try Bool.fetchOne(db, sql: "SELECT isLive FROM db_computed") == true)
            value.value = .number(13.5)
            try ComputedWriter.write([value], in: db)
            #expect(db.changesCount == 1)
            #expect(try Double.fetchOne(db, sql: "SELECT sortNumber FROM db_computed") == 13.5)
            value.value = nil
            try ComputedWriter.write([value], in: db)
            #expect(db.changesCount == 1)
            #expect(try String.fetchOne(db, sql: "SELECT value FROM db_computed") == nil)
            try ComputedWriter.write([value], in: db)
            #expect(db.changesCount == 0, "NULL сравнивается без потери пустых значений")
            // Пересчёт обязан чинить сравнимые колонки и при том же JSON.
            for column in ["sortText", "sortNumber", "searchText"] {
                try db.execute(sql: "UPDATE db_computed SET \(column) = '999'")
                try ComputedWriter.write([value], in: db)
                #expect(db.changesCount == 1, "исправлена колонка \(column)")
            }
            let empty = ComputedValue(rowId: row, propertyId: UUID(), value: nil)
            try ComputedWriter.write([empty], in: db)
            #expect(db.changesCount == 1, "отсутствующий NULL-итог вставляется для fillMissing")
            try ComputedWriter.write([empty], in: db)
            #expect(db.changesCount == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM db_computed") == 2)
            #expect(try Row.fetchOne(db, sql: "SELECT * FROM page WHERE id = ?", arguments: [row.databaseText]) == pageBefore,
                    "вычисленный кэш не меняет updatedAt или часы страницы")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM outbox_entry") == outboxBefore,
                    "вычисленный кэш не создаёт синхронизируемых записей")
        }
    }

    @Test("Сравнение использует persisted JSON: NULL, списки, порядок, числа и текст")
    func persistedRepresentations() throws {
        let queue = try DatabaseQueue()
        try SchemaMigrations.current.migrator.migrate(queue)
        let row = UUID(), property = UUID()
        let values: [JSONValue] = [.null, .bool(false), .number(0), .bool(true), .number(1), .array([]), .array([.string("А"), .number(2), .null]),
                                   .array([.number(2), .string("А"), .null]), .number(12), .number(12.5), .string("Привет")]
        try queue.write { db in
            for json in values {
                let item = ComputedValue(rowId: row, propertyId: property, value: json)
                try ComputedWriter.write([item], in: db)
                #expect(db.changesCount == 1)
                #expect(try String.fetchOne(db, sql: "SELECT value FROM db_computed") == json.jsonText)
                try ComputedWriter.write([item], in: db)
                #expect(db.changesCount == 0)
                if json == .number(12) {
                    // То же число, но другое persisted представление: запись нормализуется через JSONValue.jsonText.
                    try db.execute(sql: "UPDATE db_computed SET value = '12.0000'")
                    try ComputedWriter.write([item], in: db)
                    #expect(db.changesCount == 1)
                    #expect(try String.fetchOne(db, sql: "SELECT value FROM db_computed") == json.jsonText)
                }
                if json == .string("Привет") {
                    let expected = try Row.fetchOne(db, sql: "SELECT * FROM db_computed")
                    for column in ["sortText", "sortNumber", "searchText"] {
                        try db.execute(sql: "UPDATE db_computed SET \(column) = '999'")
                        try ComputedWriter.write([item], in: db)
                        #expect(db.changesCount == 1)
                        #expect(try Row.fetchOne(db, sql: "SELECT * FROM db_computed") == expected)
                    }
                }
            }
        }
    }

}
