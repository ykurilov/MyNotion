import CryptoKit
import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Пачка `formatVersion: 4` (T012, contracts/sync-v4-and-export.md): семь сущностей баз, у каждого поля своя метка;
/// пачки v1–v3 читаются; Mac с форматом 3 пачку v4 не применяет.
@MainActor
@Suite("Формат пачки v4")
struct SyncPayloadV4Tests {
    let hlc = HybridTimestamp(wallMillis: 1_760_000_000_000, counter: 1, deviceId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
    let id = UUID(uuidString: "0193A1B2-0000-7000-8000-000000000004")!
    let database = UUID(uuidString: "0193A1B2-0000-7000-8000-0000000000DB")!

    /// «сущность поле значение» — как их пишет пачка.
    private func encoded(_ entity: SyncChange.Entity, _ field: String, _ value: JSONValue) throws -> String {
        let change = SyncChange(entity: entity, id: id, pageId: database, value: .databaseField(field, value), hlc: hlc)
        let text = String(decoding: try SyncJSON.encoder().encode(change), as: UTF8.self)
        #expect(try SyncJSON.decoder().decode(SyncChange.self, from: Data(text.utf8)) == change, "\(entity) \(field) переживает пачку")
        #expect(text.contains(#""pageId":"\#(database.uuidString)""#), "pageId — страница-база")
        guard let valueStart = text.range(of: #","value":"#) else { return text }
        return "\(entity.rawValue) \(field) " + text[valueStart.upperBound...].dropLast()
    }

    @Test("Версия формата — 4")
    func formatVersion() {
        #expect(SyncBatch.currentFormatVersion == 4)
        #expect(SyncBatch(deviceId: "d", deviceName: "Mac", changes: []).formatVersion == 4)
        #expect(SyncSnapshot(seq: 1, changes: [], knowledge: ClockKnowledge()).formatVersion == 4)
    }

    @Test("Семь сущностей и их поля — как в контракте")
    func entitiesMatchContract() throws {
        let p = "0193a1b2-0000-7000-8000-0000000000f1", r = "0193a1b2-0000-7000-8000-0000000000f2"
        #expect(try encoded(.database, "isInline", true) == "database isInline true")
        #expect(try encoded(.database, "defaultTemplateId", .null) == "database defaultTemplateId null")
        #expect(try encoded(.property, "name", "Срок") == #"property name "Срок""#)
        #expect(try encoded(.property, "typeAndConfig", ["type": "number", "config": ["format": "percent"]])
                == #"property typeAndConfig {"config":{"format":"percent"},"type":"number"}"#)
        #expect(try encoded(.property, "sortKey", "a0V") == #"property sortKey "a0V""#)
        #expect(try encoded(.property, "deletedAt", "2026-10-21T09:15:03.120Z") == #"property deletedAt "2026-10-21T09:15:03.120Z""#)
        #expect(try encoded(.option, "color", "blue") == #"option color "blue""#)
        #expect(try encoded(.option, "placement", ["propertyId": .string(p), "sortKey": "m", "statusGroup": "todo"])
                == #"option placement {"propertyId":"\#(p)","sortKey":"m","statusGroup":"todo"}"#)
        #expect(try encoded(.view, "sorts", [["propertyId": .string(p), "direction": "descending"]])
                == #"view sorts [{"direction":"descending","propertyId":"\#(p)"}]"#)
        #expect(try encoded(.view, "layoutOptions", ["loadLimit": 25, "cardSize": "large"]) == #"view layoutOptions {"cardSize":"large","loadLimit":25}"#)
        #expect(try encoded(.cell, "value", ["propertyId": .string(p), "value": ["runs": [], "string": "банк"]])
                == #"cell value {"propertyId":"\#(p)","value":{"runs":[],"string":"банк"}}"#)
        #expect(try encoded(.cell, "value", ["propertyId": .string(p), "value": .null]) == #"cell value {"propertyId":"\#(p)","value":null}"#)
        #expect(try encoded(.relationLink, "link", ["propertyId": .string(p), "rowId": .string(r), "targetRowId": .string(r)])
                == #"relationLink link {"propertyId":"\#(p)","rowId":"\#(r)","targetRowId":"\#(r)"}"#)
        #expect(try encoded(.relationLink, "isPresent", false) == "relationLink isPresent false")
        #expect(try encoded(.rowOrder, "sortKey", ["viewId": .string(p), "rowId": .string(r), "sortKey": "m"])
                == #"rowOrder sortKey {"rowId":"\#(r)","sortKey":"m","viewId":"\#(p)"}"#)
    }

    @Test("Исходящие: все записи базы уходят своими полями, `pageId` — страница-база, ячейки строки — каждая своей")
    func outgoingRecords() throws {
        let mac = try SyncTestMac(name: "Mac", wallMillis: 10_000)
        let db = try makeTasksDatabase(on: mac)
        let changes = try mac.takeOutgoing().flatMap(\.changes)
        func fields(_ entity: SyncChange.Entity) -> Set<String> { Set(changes.filter { $0.entity == entity }.map(\.value.field)) }
        #expect(fields(.database) == ["isInline", "defaultTemplateId"])
        #expect(fields(.property) == ["name", "typeAndConfig", "sortKey", "deletedAt"])
        #expect(fields(.option) == ["name", "color", "placement", "deletedAt"])
        #expect(fields(.view) == ["name", "type", "sortKey", "filter", "sorts", "columns", "group", "layoutOptions"])
        #expect(fields(.relationLink) == ["link", "isPresent", "sortKey"])
        #expect(fields(.rowOrder) == ["sortKey"])
        let cells = changes.filter { $0.entity == .cell }
        #expect(cells.count == 2, "две ячейки одной строки — две записи")
        #expect(Set(cells.map(\.id)) == [db.row])
        for change in changes where ![.page, .block].contains(change.entity) {
            #expect(change.pageId == db.database, "\(change.entity) \(change.value.field): pageId — база")
        }
    }

    @Test("Пачки v1–v3 читаются как раньше")
    func readsOlderBatches() throws {
        let key = SymmetricKey(size: .bits256)
        let change = SyncChange(entity: .page, id: id, value: .isTemplate(true), hlc: hlc)
        for version in 1...3 {
            let sealed = try BatchCipher(key: key).seal(SyncBatch(formatVersion: version, deviceId: "d", deviceName: "Mac", changes: [change]),
                                                        batchId: "b\(version)")
            let opened = try BatchCipher(key: key).open(sealed, batchId: "b\(version)", deviceId: "d")
            #expect(opened.formatVersion == version && opened.changes == [change])
        }
    }

    @Test("Mac с форматом 3 пачку v4 не применяет и показывает «Обновите MyNotion на этом Mac»")
    func olderMacWaits() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try BatchCipher(key: key).seal(SyncBatch(deviceId: "d", deviceName: "Mac", changes: [
            SyncChange(entity: .cell, id: id, pageId: database, value: .databaseField("value", ["propertyId": "x", "value": 1]), hlc: hlc),
        ]), batchId: "b4")
        #expect(throws: BatchCipherError.newerFormat(4)) {
            try BatchCipher(key: key, supportedFormatVersion: 3).open(sealed, batchId: "b4", deviceId: "d")
        }
        #expect(BatchCipherError.newerFormat(4).errorDescription?.localizedCaseInsensitiveContains("Обновите MyNotion на этом Mac") == true)
    }
}
