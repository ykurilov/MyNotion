import Foundation
import GRDB
import Synchronization
import Testing
@testable import NotesCore

/// Свёрнутость переключателя — на этом Mac (data-model.md, «BlockViewState»; research R1): пишется сразу,
/// переживает перезапуск, не уходит в синхронизацию и не входит в отмену.
@Suite("Вид блока на этом Mac")
struct BlockViewStateTests {
    let folder: TemporaryFolder

    init() throws {
        folder = try TemporaryFolder()
    }

    /// Подписчик записи: синхронизация узнаёт о правках только так.
    final class RecordingHook: NotesWriteHook {
        let calls = Mutex(0)
        func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
            calls.withLock { $0 += 1 }
        }
    }

    private func makePage(in store: NotesStore) throws -> (pageId: UUID, toggles: [UUID]) {
        try store.write { tx in
            let page = try tx.createPage(title: "Переключатели")
            var key: FractionalSortKey?
            var ids: [UUID] = []
            for text in ["Первый", "Второй"] {
                key = .between(key, nil)
                let block = Block(pageId: page.id, kind: .toggle, text: InlineText(text), sortKey: key!)
                try tx.insertBlock(block)
                ids.append(block.id)
            }
            return (page.id, ids)
        }
    }

    @Test("Свёрнутость пишется сразу и читается по странице; развернуть — строки больше нет")
    func writesImmediately() throws {
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        let (pageId, toggles) = try makePage(in: store)
        let viewState = BlockViewStateStore(database: store.database)
        #expect(try viewState.collapsedBlockIds(ofPage: pageId).isEmpty, "Нет строки — развёрнут")

        try viewState.setCollapsed(true, blockId: toggles[1])
        #expect(try viewState.collapsedBlockIds(ofPage: pageId) == [toggles[1]])
        let rows = try store.database.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM block_view_state") }
        #expect(rows == 1)

        try viewState.setCollapsed(false, blockId: toggles[1])
        #expect(try viewState.collapsedBlockIds(ofPage: pageId).isEmpty)
    }

    @Test("Свёрнутость переживает перезапуск: база открыта заново")
    func survivesRelaunch() throws {
        var toggles: [UUID] = []
        var pageId = UUID()
        do {
            let database = try AppDatabase.open(at: folder.databaseURL)
            let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: UUID()))
            (pageId, toggles) = try makePage(in: store)
            try BlockViewStateStore(database: database).setCollapsed(true, blockId: toggles[0])
            database.close()
        }
        let reopened = try AppDatabase.open(at: folder.databaseURL)
        #expect(try BlockViewStateStore(database: reopened).collapsedBlockIds(ofPage: pageId) == [toggles[0]])
    }

    @Test("Свёрнутость не попадает в очередь исходящих и не зовёт подписчиков записи")
    func notSynced() throws {
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        let (pageId, toggles) = try makePage(in: store)
        let hook = RecordingHook()
        store.addWriteHook(hook)
        let outboxBefore = try store.database.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_entry") }
        let blocksBefore = try #require(try store.pageContent(pageId)).blocks

        let viewState = BlockViewStateStore(database: store.database)
        try viewState.setCollapsed(true, blockId: toggles[0])
        try viewState.setCollapsed(false, blockId: toggles[0])
        try viewState.setCollapsed(true, blockId: toggles[1])

        #expect(hook.calls.withLock { $0 } == 0)
        let outboxAfter = try store.database.dbWriter.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox_entry") }
        #expect(outboxAfter == outboxBefore)
        #expect(try #require(try store.pageContent(pageId)).blocks == blocksBefore, "блоки и их метки часов не тронуты")
        #expect(try viewState.collapsedBlockIds(ofPage: pageId) == [toggles[1]])
    }

    @Test("Свёрнутость чужой страницы и стёртого блока не возвращается")
    func scopedToPage() throws {
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        let first = try makePage(in: store)
        let second = try makePage(in: store)
        let viewState = BlockViewStateStore(database: store.database)
        try viewState.setCollapsed(true, blockId: first.toggles[0])
        try viewState.setCollapsed(true, blockId: second.toggles[0])
        #expect(try viewState.collapsedBlockIds(ofPage: first.pageId) == [first.toggles[0]])

        try store.write { tx in try tx.deleteBlock(first.toggles[0]) }
        #expect(try viewState.collapsedBlockIds(ofPage: first.pageId).isEmpty)
    }
}
