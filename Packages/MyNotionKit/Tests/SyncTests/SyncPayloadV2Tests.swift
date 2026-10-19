import CryptoKit
import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Пачка `formatVersion: 2` (contracts/sync-and-files-api.md): новые поля блока, сущность `reminder`, новые оформления;
/// пачки v1 читаются, Mac версии 1 пачку v2 не применяет.
@MainActor
@Suite("Формат пачки v2")
struct SyncPayloadV2Tests {
    let hlc = HybridTimestamp(wallMillis: 1_760_000_000_000, counter: 1, deviceId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)
    let blockId = UUID(uuidString: "0193A1B2-0000-7000-8000-000000000002")!
    let pageId = UUID(uuidString: "0193A1B2-0000-7000-8000-000000000003")!
    let containerId = UUID(uuidString: "0193A1B2-0000-7000-8000-000000000004")!

    private func json(_ change: SyncChange) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: try SyncJSON.encoder().encode(change)) as? [String: Any])
    }

    private func roundTrip(_ change: SyncChange) throws -> SyncChange {
        try SyncJSON.decoder().decode(SyncChange.self, from: try SyncJSON.encoder().encode(change))
    }

    @Test("Версия формата — 2")
    func formatVersion() {
        #expect(SyncBatch.currentFormatVersion == 2)
        #expect(SyncBatch(deviceId: "d", deviceName: "Mac", changes: []).formatVersion == 2)
        #expect(SyncSnapshot(seq: 1, changes: [], knowledge: ClockKnowledge()).formatVersion == 2)
    }

    @Test("placement блока: {containerId, sortKey}, контейнер пустой — null")
    func placementEncoding() throws {
        let inColumn = SyncChange(entity: .block, id: blockId, pageId: pageId,
                                  value: .blockPlacement(containerId: containerId, sortKey: "m"), hlc: hlc)
        let encoded = try json(inColumn)
        #expect(encoded["field"] as? String == "placement")
        let value = try #require(encoded["value"] as? [String: Any])
        #expect((value["containerId"] as? String)?.lowercased() == containerId.uuidString.lowercased())
        #expect(value["sortKey"] as? String == "m")
        #expect(try roundTrip(inColumn) == inColumn)

        let onPage = SyncChange(entity: .block, id: blockId, pageId: pageId, value: .blockPlacement(containerId: nil, sortKey: "n"), hlc: hlc)
        let pageValue = try #require(try json(onPage)["value"] as? [String: Any])
        #expect(pageValue["containerId"] is NSNull)
        #expect(try roundTrip(onPage) == onPage)
        // У страницы своё поле placement — {parentId, sortKey}: оно не путается с блоком.
        let page = SyncChange(entity: .page, id: pageId, value: .placement(parentId: nil, sortKey: "a"), hlc: hlc)
        #expect(try roundTrip(page) == page)
    }

    @Test("color и props блока; неизвестные ключи props переживают пачку")
    func colorAndProps() throws {
        let color = SyncChange(entity: .block, id: blockId, pageId: pageId, value: .color(BlockColor(background: .gray)), hlc: hlc)
        let colorValue = try #require(try json(color)["value"] as? [String: Any])
        #expect(colorValue["background"] as? String == "gray")
        #expect(colorValue["text"] is NSNull)
        #expect(try roundTrip(color) == color)

        let props = try JSONDecoder().decode(BlockProps.self, from: Data(#"{"icon":"💡","future":{"x":[1,2]}}"#.utf8))
        let change = SyncChange(entity: .block, id: blockId, pageId: pageId, value: .props(props), hlc: hlc)
        #expect(try json(change)["field"] as? String == "props")
        let decoded = try roundTrip(change)
        #expect(decoded == change)
        guard case .props(let back) = decoded.value else { Issue.record("не props"); return }
        #expect(back.values["future"] == .object(["x": .array([.number(1), .number(2)])]))
    }

    @Test("Сущность reminder: {entity: reminder, id: mentionId, field: doneAt, value: ISO | null}")
    func reminderEntity() throws {
        let mentionId = UUID()
        let done = SyncChange(entity: .reminder, id: mentionId, value: .doneAt(Date(timeIntervalSince1970: 1_760_000_000)), hlc: hlc)
        let encoded = try json(done)
        #expect(encoded["entity"] as? String == "reminder")
        #expect(encoded["field"] as? String == "doneAt")
        #expect(encoded["value"] as? String == "2025-10-09T08:53:20.000Z")
        #expect(try roundTrip(done) == done)

        let undone = SyncChange(entity: .reminder, id: mentionId, value: .doneAt(nil), hlc: hlc)
        #expect(try json(undone)["value"] is NSNull)
        #expect(try roundTrip(undone) == undone)
    }

    @Test("Новые оформления в text.runs проходят пачку без изменений")
    func inlineStylesInText() throws {
        let date = DateMention(id: UUID(), start: "2026-10-20", includesTime: false, timeZone: "Asia/Makassar",
                               reminder: .init(fireAt: Date(timeIntervalSince1970: 1_760_918_400)))
        let text = InlineText("цвет \u{FFFC}\u{FFFC}\u{FFFC}", runs: [
            StyledRun(start: 0, length: 4, style: .textColor(.red)),
            StyledRun(start: 0, length: 4, style: .backgroundColor(.yellow)),
            StyledRun(start: 5, length: 1, style: .mention(UUID())),
            StyledRun(start: 6, length: 1, style: .date(date)),
            StyledRun(start: 7, length: 1, style: .equation("x^2")),
        ])
        let change = SyncChange(entity: .block, id: blockId, pageId: pageId, value: .text(text), hlc: hlc)
        #expect(try roundTrip(change) == change)
    }

    @Test("Новые типы блоков — в kindAndIndent")
    func newKinds() throws {
        for kind in [BlockKind.toggle, .callout, .tableCell, .columnList] {
            let change = SyncChange(entity: .block, id: blockId, pageId: pageId, value: .kindAndIndent(kind: kind, indent: 1, linkedPageId: nil), hlc: hlc)
            #expect(try roundTrip(change) == change)
        }
    }

    @Test("Пачка v1 с sortKey читается как placement с прежним контейнером")
    func v1SortKeyKeepsContainer() throws {
        let v1 = """
            {"deviceId":"d","deviceName":"Старый Mac","formatVersion":1,"changes":[
            {"entity":"block","field":"sortKey","hlc":"\(HybridTimestamp(wallMillis: 90_000, counter: 0, deviceId: UUID()).description)",\
            "id":"\(blockId.uuidString)","pageId":"\(pageId.uuidString)","value":"zz"}]}
            """
        let batch = try SyncJSON.decoder().decode(SyncBatch.self, from: Data(v1.utf8))
        #expect(batch.formatVersion == 1)
        #expect(batch.changes.first?.value == .sortKey("zz"))

        let mac = try SyncTestMac(name: "Mac", wallMillis: 10_000)
        let column = UUID()
        try mac.store.write { tx in
            try tx.insertPage(Page(id: pageId, title: "Колонки", sortKey: .between(nil, nil), createdAt: Date(), updatedAt: Date()))
            try tx.insertBlock(Block(id: blockId, pageId: pageId, text: InlineText("в колонке"), sortKey: .between(nil, nil), containerId: column))
        }
        try mac.receive([batch], numbering: TestJournalNumbering())
        let block = try #require(try mac.store.write { try $0.block(blockId) })
        #expect(block.sortKey.rawValue == "zz")
        #expect(block.containerId == column, "контейнер прежний")
    }

    @Test("Mac с форматом 1 пачку v2 не применяет и ждёт обновления")
    func olderMacWaits() throws {
        let key = SymmetricKey(size: .bits256)
        let sealed = try BatchCipher(key: key).seal(SyncBatch(deviceId: "d", deviceName: "Mac", changes: []), batchId: "b1")
        #expect(throws: BatchCipherError.newerFormat(2)) {
            try BatchCipher(key: key, supportedFormatVersion: 1).open(sealed, batchId: "b1", deviceId: "d")
        }
        let opened = try BatchCipher(key: key).open(sealed, batchId: "b1", deviceId: "d")
        #expect(opened.formatVersion == 2)
    }

    @Test("Исходящие поля блока: placement, color, props вместо sortKey")
    func outgoingFields() throws {
        let mac = try SyncTestMac(name: "Mac", wallMillis: 10_000)
        let ids = try mac.store.write { tx in
            let page = try tx.createPage(title: "Новые поля")
            var block = try #require(try tx.blocks(ofPage: page.id).first)
            block.kind = .callout
            block.color = BlockColor(background: .gray)
            block.props = .defaults(for: .callout)
            block.containerId = UUID()
            try tx.updateBlock(block)
            return block.id
        }
        let changes = try mac.takeOutgoing().flatMap(\.changes).filter { $0.id == ids }
        let fields = Set(changes.map(\.value.field))
        #expect(fields.isSuperset(of: ["kindAndIndent", "text", "isChecked", "placement", "color", "props"]))
        #expect(!fields.contains("sortKey"))
    }
}
