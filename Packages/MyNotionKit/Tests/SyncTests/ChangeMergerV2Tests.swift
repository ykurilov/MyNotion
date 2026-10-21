import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Слияние полей 002 (contracts/sync-and-files-api.md): `placement`, `color`, `props`, отметка напоминания —
/// позднее побеждает; удаление контейнера, не видевшее правку внутри, отменяется; снимок несёт все потоки.
@MainActor
@Suite("Слияние правок v2")
struct ChangeMergerV2Tests {
    let numbering = TestJournalNumbering()
    let a: SyncTestMac
    let b: SyncTestMac

    init() throws {
        a = try SyncTestMac(name: "Mac A", wallMillis: 10_000)
        b = try SyncTestMac(name: "Mac B", wallMillis: 10_000)
    }

    private func update(_ mac: SyncTestMac, _ blockId: UUID, _ change: (inout Block) -> Void) throws {
        try mac.store.write { tx in
            var block = try #require(try tx.block(blockId))
            change(&block)
            try tx.updateBlock(block)
        }
    }

    /// Таблица: столбец, строка, ячейка в ней; доставлена на оба Mac.
    private func sharedTable() throws -> (page: UUID, table: UUID, column: UUID, row: UUID, cell: UUID) {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        let ids = try a.store.write { tx in
            let anchor = try #require(try tx.block(shared.block))
            let table = try tx.insertBlock(Block(pageId: shared.page, kind: .table, sortKey: .between(anchor.sortKey, nil),
                                                 props: .defaults(for: .table)))
            let column = try tx.insertBlock(Block(pageId: shared.page, kind: .tableColumn, sortKey: .between(nil, nil),
                                                  containerId: table.id, props: .defaults(for: .tableColumn)))
            let row = try tx.insertBlock(Block(pageId: shared.page, kind: .tableRow, sortKey: .between(column.sortKey, nil), containerId: table.id))
            var cellProps = BlockProps.empty
            cellProps.columnId = column.id
            let cell = try tx.insertBlock(Block(pageId: shared.page, kind: .tableCell, text: InlineText("ячейка"),
                                                sortKey: .between(nil, nil), containerId: row.id, props: cellProps))
            return (shared.page, table.id, column.id, row.id, cell.id)
        }
        try exchange([a, b], numbering: numbering)
        return ids
    }

    @Test("placement, color, props: позднее побеждает, у каждого поля своя метка")
    func laterFieldWins() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        let column = UUID()
        a.wall.set(30_000)
        try update(a, shared.block) {
            $0.color = BlockColor(text: .red)
            $0.containerId = column
        }
        b.wall.set(40_000)
        try update(b, shared.block) {
            $0.color = BlockColor(background: .yellow)
            $0.props.icon = "🔥"
        }
        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            let block = try #require(try mac.store.write { try $0.block(shared.block) })
            #expect(block.color == BlockColor(background: .yellow), "\(mac.name): позднее значение цвета")
            #expect(block.props.icon == "🔥", "\(mac.name)")
            #expect(block.containerId == column, "\(mac.name): место меняли только на A")
            #expect(try mac.conflicts().isEmpty)
        }
    }

    @Test("reminder.doneAt: позднее побеждает в любом порядке пачек")
    func reminderLaterWins() throws {
        let mentionId = UUID()
        let device = UUID()
        let early = SyncChange(entity: .reminder, id: mentionId, value: .doneAt(nil),
                               hlc: HybridTimestamp(wallMillis: 20_000, counter: 0, deviceId: device))
        let doneAt = Date(timeIntervalSince1970: 1_760_000_000)
        let late = SyncChange(entity: .reminder, id: mentionId, value: .doneAt(doneAt),
                              hlc: HybridTimestamp(wallMillis: 30_000, counter: 0, deviceId: device))
        try a.receive([SyncBatch(deviceId: "x", deviceName: "X", changes: [early]),
                       SyncBatch(deviceId: "x", deviceName: "X", changes: [late])], numbering: numbering)
        try b.receive([SyncBatch(deviceId: "x", deviceName: "X", changes: [late]),
                       SyncBatch(deviceId: "x", deviceName: "X", changes: [early])], numbering: numbering)
        for mac in [a, b] {
            let state = try #require(try mac.store.write { try $0.reminderState(mentionId) })
            #expect(state.doneAt == doneAt, "\(mac.name)")
            #expect(state.doneClock == late.hlc)
        }
    }

    @Test("Удаление строки, не видевшее правку ячейки, отменяется — строка возвращается на обоих Mac")
    func rowDeletionLosesToCellEdit() throws {
        let table = try sharedTable()
        a.wall.set(30_000)
        try a.store.write { tx in
            try tx.deleteBlock(table.cell)
            try tx.deleteBlock(table.row)
        }
        b.wall.set(31_000)
        try update(b, table.cell) { $0.text = InlineText("правка на B") }
        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            let blocks = try mac.blocks(table.page)
            #expect(blocks.contains { $0.id == table.row }, "\(mac.name): строка вернулась")
            #expect(blocks.first { $0.id == table.cell }?.text.string == "правка на B", "\(mac.name)")
            #expect(blocks.first { $0.id == table.cell }?.containerId == table.row)
        }
    }

    @Test("Удаление столбца, не видевшее правку ячейки, отменяется")
    func columnDeletionLosesToCellEdit() throws {
        let table = try sharedTable()
        a.wall.set(30_000)
        try a.store.write { tx in try tx.deleteBlock(table.column) }
        b.wall.set(31_000)
        try update(b, table.cell) { $0.text = InlineText("в удалённом столбце") }
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            #expect(try mac.blocks(table.page).contains { $0.id == table.column }, "\(mac.name): столбец вернулся")
        }
    }

    @Test("Удаление, видевшее все правки, проходит: строка и ячейка удалены на обоих Mac")
    func knownDeletionWins() throws {
        let table = try sharedTable()
        a.wall.set(30_000)
        try a.store.write { tx in
            try tx.deleteBlock(table.cell)
            try tx.deleteBlock(table.row)
        }
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            let ids = Set(try mac.blocks(table.page).map(\.id))
            #expect(!ids.contains(table.row) && !ids.contains(table.cell), "\(mac.name)")
            #expect(ids.contains(table.table) && ids.contains(table.column))
        }
    }

    @Test("Блок, добавленный в удалённую колонку, не теряется")
    func blockInDeletedColumnSurvives() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        let (list, column) = try a.store.write { tx in
            let anchor = try #require(try tx.block(shared.block))
            let list = try tx.insertBlock(Block(pageId: shared.page, kind: .columnList, sortKey: .between(anchor.sortKey, nil)))
            let column = try tx.insertBlock(Block(pageId: shared.page, kind: .column, sortKey: .between(nil, nil), containerId: list.id))
            return (list.id, column.id)
        }
        try exchange([a, b], numbering: numbering)

        a.wall.set(30_000)
        try a.store.write { tx in try tx.deleteBlock(column) }
        b.wall.set(31_000)
        let added = try b.store.write { tx in
            try tx.insertBlock(Block(pageId: shared.page, text: InlineText("новое в колонке"), sortKey: .between(nil, nil), containerId: column)).id
        }
        try exchange([a, b], numbering: numbering)

        for mac in [a, b] {
            let blocks = try mac.blocks(shared.page)
            #expect(blocks.first { $0.id == added }?.text.string == "новое в колонке", "\(mac.name): блок на месте")
            #expect(blocks.contains { $0.id == column }, "\(mac.name): колонка вернулась")
            #expect(blocks.contains { $0.id == list })
        }
    }

    @Test("Снимок v2 несёт блоки всех потоков с местом, цветом и свойствами")
    func snapshotCarriesAllFlows() throws {
        let table = try sharedTable()
        try update(a, table.cell) { $0.color = BlockColor(text: .blue) }
        let snapshot = try SyncSnapshot.make(seq: 42, from: a.store)
        #expect(snapshot.formatVersion == SyncBatch.currentFormatVersion)

        let fresh = try SyncTestMac(name: "Mac C", wallMillis: 50_000)
        _ = try fresh.store.write { tx in try ChangeMerger(localDeviceName: "Mac C").apply(snapshot, in: tx) }
        // Свойства — JSON с ключами по алфавиту: у словаря порядок ключей при печати случайный.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func describe(_ blocks: [Block]) -> [String] {
            blocks.map { block in
                let props = String(decoding: (try? encoder.encode(block.props)) ?? Data(), as: UTF8.self)
                return "\(block.id) \(block.kind) \(block.containerId?.uuidString ?? "-") \(block.sortKey.rawValue) \(block.color) \(props) \(block.text.string)"
            }.sorted()
        }
        let got = describe(try fresh.blocks(table.page)), want = describe(try a.blocks(table.page))
        #expect(got == want, "\(got.count) против \(want.count): \(Set(got).symmetricDifference(want))")
    }
}
