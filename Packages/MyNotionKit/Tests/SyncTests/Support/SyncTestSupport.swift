import Foundation
import GRDB
import Synchronization
import Testing
@testable import NotesCore
@testable import Sync

/// Системные часы Mac под управлением теста.
final class AdjustableWallClock: Sendable {
    private let currentMillis: Mutex<Int64>

    init(millis: Int64 = 1_000) {
        currentMillis = Mutex(millis)
    }

    func set(_ millis: Int64) {
        currentMillis.withLock { $0 = millis }
    }

    var reading: @Sendable () -> Int64 {
        { [self] in currentMillis.withLock { $0 } }
    }
}

/// Пустая папка на время теста; стирается вместе с объектом.
final class TemporaryFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotionSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var databaseURL: URL { url.appendingPathComponent("MyNotion.sqlite") }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Часы автосохранения под управлением теста: время идёт только по `advance(by:)`.
@MainActor
final class ManualAutosaveScheduler: AutosaveScheduler {
    private(set) var now: Duration = .zero
    private var pending: [PendingAction] = []
    private var nextOrder = 0

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAutosave {
        let entry = PendingAction(dueAt: now + max(delay, .zero), order: nextOrder, action: action)
        nextOrder += 1
        pending.append(entry)
        return entry
    }

    func advance(by duration: Duration) {
        let target = now + duration
        while let next = pending.filter({ !$0.isCancelled && $0.dueAt <= target })
            .min(by: { ($0.dueAt, $0.order) < ($1.dueAt, $1.order) }) {
            now = next.dueAt
            next.isCancelled = true
            pending.removeAll { $0.isCancelled }
            next.action()
        }
        pending.removeAll { $0.isCancelled }
        now = target
    }

    private final class PendingAction: ScheduledAutosave {
        let dueAt: Duration
        let order: Int
        let action: @MainActor () -> Void
        var isCancelled = false

        init(dueAt: Duration, order: Int, action: @escaping @MainActor () -> Void) {
            self.dueAt = dueAt
            self.order = order
            self.action = action
        }

        func cancel() { isCancelled = true }
    }
}

/// Номера пачек, как у журнала сервера: общий счётчик для всех Mac теста.
final class TestJournalNumbering {
    private(set) var lastSeq = 0
    func next() -> Int {
        lastSeq += 1
        return lastSeq
    }
}

/// Один Mac со своей базой, часами и включённой синхронизацией, но без сервера:
/// пачки из его очереди тест передаёт другим Mac сам (`exchange`).
@MainActor
final class SyncTestMac {
    let name: String
    let folder: TemporaryFolder
    let wall: AdjustableWallClock
    let store: NotesStore
    let serverDeviceId: String
    let scheduler = ManualAutosaveScheduler()
    let documents: OpenDocuments
    let applier: RemoteChangeApplier
    let tree: PageTreeOperations
    /// Уведомления, которые получил бы Юрий на этом Mac.
    private(set) var notices: [SyncNotice] = []

    init(name: String, wallMillis: Int64) throws {
        self.name = name
        folder = try TemporaryFolder()
        wall = AdjustableWallClock(millis: wallMillis)
        store = NotesStore(database: try AppDatabase.open(at: folder.databaseURL),
                           clock: HybridLogicalClock(deviceId: UUID(), wallClock: wall.reading))
        serverDeviceId = UUID().uuidString.lowercased()
        Outbox.install(on: store)
        try SyncSetup.enable(store: store, account: SyncAccount(
            serverURL: URL(string: "https://sync.test")!, deviceId: serverDeviceId, deviceName: name))
        documents = OpenDocuments(store: store, scheduler: scheduler)
        applier = RemoteChangeApplier(store: store, openDocuments: documents, localDeviceName: name)
        tree = PageTreeOperations(store: store)
    }

    /// Забрать из очереди всё, что этот Mac отправил бы на сервер.
    func takeOutgoing() throws -> [SyncBatch] {
        let outbox = Outbox(store: store)
        let entries = try outbox.pendingEntries()
        for entry in entries { try outbox.remove(entry.id) }
        return entries.map { SyncBatch(deviceId: serverDeviceId, deviceName: name, changes: $0.changes) }
    }

    /// Применить пачки с других Mac, как будто они пришли с сервера по порядку.
    @discardableResult
    func receive(_ batches: [SyncBatch], numbering: TestJournalNumbering) throws -> MergeReport {
        let received = batches.map { ReceivedBatch(seq: numbering.next(), batchId: UUID().uuidString, batch: $0) }
        let report = try applier.apply(received)
        notices += report.notices
        return report
    }

    // MARK: Чтение

    func page(_ id: UUID) throws -> Page? {
        try store.pageOutline().first { $0.id == id }
    }

    func blocks(_ pageId: UUID) throws -> [Block] {
        try store.pageContent(pageId)?.blocks ?? []
    }

    func block(_ id: UUID, in pageId: UUID) throws -> Block? {
        try blocks(pageId).first { $0.id == id }
    }

    /// Неразрешённые конфликты по всем страницам.
    func conflicts() throws -> [Conflict] {
        try store.pageOutline().flatMap { try store.unresolvedConflicts(ofPage: $0.id) }
    }

    /// Родитель каждой страницы — для сравнения деревьев двух Mac.
    func parents() throws -> [UUID: UUID?] {
        Dictionary(uniqueKeysWithValues: try store.pageOutline().map { ($0.id, $0.parentId) })
    }

    // MARK: Правки

    func setText(_ text: String, ofBlock blockId: UUID) throws {
        try store.write { tx in
            var block = try #require(try tx.block(blockId))
            block.text = InlineText(text)
            try tx.updateBlock(block)
        }
    }

    func rename(_ pageId: UUID, _ title: String) throws {
        try tree.rename(pageId, to: title)
    }
}

/// Передавать пачки между Mac, пока у всех не опустеют очереди (ответы на ответы тоже доходят).
@MainActor
func exchange(_ macs: [SyncTestMac], numbering: TestJournalNumbering, rounds: Int = 6) throws {
    for _ in 0..<rounds {
        var anything = false
        for sender in macs {
            let batches = try sender.takeOutgoing()
            guard !batches.isEmpty else { continue }
            anything = true
            for receiver in macs where receiver !== sender {
                try receiver.receive(batches, numbering: numbering)
            }
        }
        if !anything { return }
    }
    Issue.record("Очереди не опустели за \(rounds) кругов: Mac отвечают друг другу бесконечно")
}

/// Новая страница с одним блоком на `mac`, доставленная на все `others`.
@MainActor
func sharedPage(on mac: SyncTestMac, others: [SyncTestMac], numbering: TestJournalNumbering,
                title: String = "Общая", text: String = "текст", parentId: UUID? = nil) throws -> (page: UUID, block: UUID) {
    let ids = try mac.store.write { tx in
        let page = try tx.createPage(title: title, parentId: parentId)
        var block = try #require(try tx.blocks(ofPage: page.id).first)
        block.text = InlineText(text)
        try tx.updateBlock(block)
        return (page.id, block.id)
    }
    try exchange([mac] + others, numbering: numbering)
    return ids
}

/// Всё содержимое базы, что видит Юрий и что нужно синхронизации, — для сравнения «ничего не изменилось».
func contentDump(_ store: NotesStore) throws -> String {
    try store.database.dbWriter.read { db in
        var lines: [String] = []
        for table in ["page", "block", "conflict", "page_tombstone"] {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
            lines.append("\(table): \(rows.map(\.description).joined(separator: "; "))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Сколько блоков лежит пометками «удалён».
func deletionMarkCount(_ store: NotesStore) throws -> Int {
    try store.database.dbWriter.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM block WHERE isDeleted = 1") ?? 0
    }
}
