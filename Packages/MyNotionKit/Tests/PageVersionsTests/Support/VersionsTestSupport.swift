import Foundation
import Synchronization
@testable import NotesCore
@testable import PageVersions
@testable import Sync

/// Пустая папка на время теста; стирается вместе с объектом.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionVersionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var databaseURL: URL { url.appendingPathComponent("MyNotion.sqlite") }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Часы теста: время идёт только по `advance(by:)`; запланированные проверки записывателя выполняются в порядке сроков.
final class ManualVersionClock: VersionRecordingScheduler, @unchecked Sendable {
    private struct Pending {
        let dueAt: Date
        let order: Int
        let work: @Sendable () -> Void
    }

    private let state = Mutex<(now: Date, pending: [Pending], order: Int)>((Date(timeIntervalSince1970: 1_800_000_000), [], 0))

    var now: Date { state.withLock { $0.now } }
    var reading: @Sendable () -> Date { { [self] in now } }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        state.withLock { state in
            state.pending.append(Pending(dueAt: state.now.addingTimeInterval(max(delay, 0)), order: state.order, work: work))
            state.order += 1
        }
    }

    /// Сдвинуть время, выполняя всё, что наступило по дороге (и то, что запланировано по дороге).
    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = state.withLock({ state -> Pending? in
            guard let index = state.pending.indices.filter({ state.pending[$0].dueAt <= target })
                .min(by: { (state.pending[$0].dueAt, state.pending[$0].order) < (state.pending[$1].dueAt, state.pending[$1].order) })
            else { return nil }
            let next = state.pending.remove(at: index)
            state.now = max(state.now, next.dueAt)
            return next
        }) {
            next.work()
        }
        state.withLock { $0.now = target }
    }

    /// Выполнить то, что уже наступило.
    func runDue() { advance(by: 0) }

    var pendingCount: Int { state.withLock { $0.pending.count } }
}

/// Mac с базой, записью версий и (по желанию) синхронизацией через ручную передачу пачек.
@MainActor
final class VersionsTestMac {
    let name: String
    let folder: TemporaryFolder
    let store: NotesStore
    let clock: ManualVersionClock
    let versions: PageVersionStore
    let recorder: PageVersionRecorder
    let tree: PageTreeOperations
    let undoManager = UndoManager()
    private(set) var serverDeviceId = UUID().uuidString.lowercased()

    init(name: String = "Mac A", clock: ManualVersionClock = ManualVersionClock(), syncs: Bool = false) throws {
        self.name = name
        self.clock = clock
        folder = try TemporaryFolder()
        store = NotesStore(database: try AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        versions = PageVersionStore(store: store)
        recorder = PageVersionRecorder(store: store, versions: versions, now: clock.reading, scheduler: clock)
        recorder.installDueMarker(localDeviceName: name)
        if syncs {
            Outbox.install(on: store)
            try SyncSetup.enable(store: store, account: SyncAccount(serverURL: URL(string: "https://sync.test")!,
                                                                    deviceId: serverDeviceId, deviceName: name))
        }
        tree = PageTreeOperations(store: store)
    }

    /// Отмена окна: без открытой группы `UndoManager` записи не принимает.
    func undoable<T>(_ action: () throws -> T) rethrows -> T {
        undoManager.groupsByEvent = false
        tree.undoManager = undoManager
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return try action()
    }

    /// Страница с абзацами `texts`.
    @discardableResult
    func page(_ title: String, texts: [String]) throws -> Page {
        try store.write { tx in
            let page = try tx.createPage(title: title)
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for text in texts {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: page.id, text: InlineText(text), sortKey: key!))
            }
            return page
        }
    }

    func blocks(_ pageId: UUID) throws -> [Block] {
        try store.pageContent(pageId)?.blocks ?? []
    }

    func texts(_ pageId: UUID) throws -> [String] {
        try blocks(pageId).map(\.text.string)
    }

    func setText(_ text: String, ofBlock blockId: UUID) throws {
        try store.write { tx in
            var block = try tx.block(blockId)!
            block.text = InlineText(text)
            try tx.updateBlock(block)
        }
    }

    func updatePage(_ pageId: UUID, _ change: (inout Page) -> Void) throws {
        try store.write { tx in
            var page = try tx.page(pageId)!
            change(&page)
            try tx.updatePage(page)
        }
    }

    func versionList(_ pageId: UUID) throws -> [PageVersionInfo] {
        try versions.versions(ofPage: pageId)
    }

    func dueCount() throws -> Int {
        try versions.duePages().count
    }

    /// Пачки этого Mac для другого — как с сервера.
    func takeOutgoing() throws -> [SyncBatch] {
        let outbox = Outbox(store: store)
        let entries = try outbox.pendingEntries()
        for entry in entries { try outbox.remove(entry.id) }
        return entries.map { SyncBatch(deviceId: serverDeviceId, deviceName: name, changes: $0.changes) }
    }

    func receive(_ batches: [SyncBatch]) throws {
        let merger = ChangeMerger(localDeviceName: name)
        for batch in batches {
            try store.write { tx in _ = try merger.apply(batch, in: tx) }
        }
    }
}
