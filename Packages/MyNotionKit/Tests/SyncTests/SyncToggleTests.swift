import CryptoKit
import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Синхронизация — отдельный модуль (FR-024): выключение удаляет подключение и очередь, записи остаются,
/// ядро работает как прежде.
@MainActor
@Suite("Включение и выключение синхронизации")
struct SyncToggleTests {
    let folder: TemporaryFolder
    let store: NotesStore
    let secrets = InMemorySyncSecrets()

    init() throws {
        folder = try TemporaryFolder()
        store = NotesStore(database: try AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        Outbox.install(on: store)
    }

    func account() -> SyncAccount {
        SyncAccount(serverURL: URL(string: "https://sync.test")!, deviceId: "device-1", deviceName: "Mac A")
    }

    @Test("Пока синхронизация не включена, очередь исходящих пуста, а удалённое стирается сразу")
    func disabledSyncKeepsCoreAsBefore() throws {
        let page = try store.write { try $0.createPage(title: "Без синхронизации") }
        let block = try #require(try store.pageContent(page.id)?.blocks.first)
        try store.write { tx in
            try tx.insertBlock(Block(pageId: page.id, text: InlineText("второй"), sortKey: .between(block.sortKey, nil)))
            try tx.deleteBlock(block.id)
        }
        #expect(try Outbox(store: store).pendingEntries().isEmpty)
        #expect(try deletionMarkCount(store) == 0)
        #expect(try SyncAccountStore(store: store).account() == nil)
    }

    @Test("Включение кладёт в очередь уже существующие записи; дальше каждая правка попадает в очередь в той же транзакции")
    func enablingQueuesExistingRecordsAndNewEdits() throws {
        let page = try store.write { try $0.createPage(title: "Была до синхронизации") }
        try SyncSetup.enable(store: store, account: account())

        let initial = try Outbox(store: store).pendingEntries().flatMap(\.changes)
        #expect(initial.contains { $0.id == page.id && $0.value == .title("Была до синхронизации") })

        try store.write { tx in
            var stored = try #require(try tx.page(page.id))
            stored.title = "Переименована"
            try tx.updatePage(stored)
        }
        let all = try Outbox(store: store).pendingEntries().flatMap(\.changes)
        #expect(all.contains { $0.id == page.id && $0.value == .title("Переименована") })
    }

    @Test("Выключение удаляет подключение, очередь, ключ и токен; записи не меняются, ядро работает")
    func disablingRemovesAccountAndQueueButKeepsRecords() throws {
        try secrets.save(SyncSecretValues(deviceToken: "token", encryptionKey: SymmetricKey(size: .bits256)), for: "device-1")
        try SyncSetup.enable(store: store, account: account())
        let page = try store.write { try $0.createPage(title: "Заметка") }
        let block = try #require(try store.pageContent(page.id)?.blocks.first)
        try store.write { tx in
            try tx.insertBlock(Block(pageId: page.id, text: InlineText("останется"), sortKey: .between(block.sortKey, nil)))
            try tx.deleteBlock(block.id)
        }
        let erased = try store.write { try $0.createPage(title: "Сотру") }
        let operations = PageTreeOperations(store: store)
        try operations.moveToTrash(erased.id)
        try operations.deleteForever(erased.id)
        #expect(try deletionMarkCount(store) == 1)
        let contentBefore = try store.pageContent(page.id)
        let outlineBefore = try store.pageOutline()

        try SyncSetup.disable(store: store, secrets: secrets)

        #expect(try SyncAccountStore(store: store).account() == nil)
        #expect(try Outbox(store: store).pendingEntries().isEmpty)
        #expect(try secrets.load(for: "device-1") == nil)
        #expect(try store.pageContent(page.id) == contentBefore, "Записи не меняются")
        #expect(try store.pageOutline() == outlineBefore)
        #expect(try deletionMarkCount(store) == 0, "Без синхронизации пометкам ждать некого")
        #expect(try store.pageTombstones().isEmpty)

        let later = try store.write { try $0.createPage(title: "После выключения") }
        #expect(try store.pageOutline().contains { $0.id == later.id })
        #expect(try Outbox(store: store).pendingEntries().isEmpty)
    }
}
