import Foundation
import Synchronization
import Testing
@testable import NotesCore
@testable import Reminders

/// Пустая папка на время теста; стирается вместе с объектом.
final class TemporaryFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotionReminderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Часы теста: время идёт только по `advance`.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date) { current = Mutex(start) }

    var now: Date { current.withLock { $0 } }
    func advance(by seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }

    var reading: @Sendable () -> Date { { [self] in now } }
}

/// Центр уведомлений теста: очередь и показанные. Время наступления очередь сама не проверяет — как Mac во сне,
/// пока тест не скажет `fireDue`.
@MainActor
final class FakeNotificationCenter: ReminderNotificationCenter {
    private(set) var pending: [String: ReminderNotificationRequest] = [:]
    private(set) var delivered: [String: ReminderNotificationRequest] = [:]
    /// Сколько раз уведомление появлялось на экране — по идентификатору.
    private(set) var shownCount: [String: Int] = [:]
    private(set) var addCount = 0

    /// Эти уведомления система не принимает (например, их стало слишком много).
    var refused: Set<String> = []

    nonisolated func add(_ request: ReminderNotificationRequest) async throws {
        let isRefused = await MainActor.run { refused.contains(request.identifier) }
        if isRefused { throw CocoaError(.featureUnsupported) }
        await MainActor.run { self.store(request) }
    }

    private func store(_ request: ReminderNotificationRequest) {
        addCount += 1
        if request.fireAt == nil {
            pending[request.identifier] = nil
            show(request)
        } else {
            pending[request.identifier] = request
        }
    }

    private func show(_ request: ReminderNotificationRequest) {
        delivered[request.identifier] = request
        shownCount[request.identifier, default: 0] += 1
    }

    /// Система показала всё, чьё время пришло (Mac не спал).
    func fireDue(at moment: Date) {
        for (identifier, request) in pending where request.fireAt.map({ $0 <= moment }) ?? true {
            pending[identifier] = nil
            show(request)
        }
    }

    nonisolated func pendingIdentifiers() async -> [String] {
        await MainActor.run { Array(pending.keys) }
    }

    nonisolated func removePending(_ identifiers: [String]) async {
        await MainActor.run { for identifier in identifiers { pending[identifier] = nil } }
    }

    nonisolated func removeDelivered(_ identifiers: [String]) async {
        await MainActor.run { for identifier in identifiers { delivered[identifier] = nil } }
    }
}

/// База с индексом напоминаний на записи.
final class ReminderLibrary: Sendable {
    let folder: TemporaryFolder
    let store: NotesStore
    private let recorded = ChangeLog()
    var changes: ChangeLog { recorded }

    init(deviceId: UUID = UUID()) throws {
        folder = try TemporaryFolder()
        store = NotesStore(database: try AppDatabase.open(at: folder.url.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: deviceId))
        let recorded = recorded
        store.addWriteHook(ReminderIndexer { change in recorded.append(change) })
    }

    var index: ReminderIndex { ReminderIndex(store: store) }

    /// Страница с одним блоком, в тексте которого даты `dates` (подряд, через пробел после слова «Позвонить»).
    @discardableResult
    func page(title: String = "Дела", dates: [DateMention], parentId: UUID? = nil) throws -> (page: UUID, block: UUID) {
        try store.write { tx in
            let page = try tx.createPage(title: title, parentId: parentId)
            var block = try #require(try tx.blocks(ofPage: page.id).first)
            block.text = Self.text(with: dates)
            try tx.updateBlock(block)
            return (page.id, block.id)
        }
    }

    func setText(_ text: InlineText, ofBlock blockId: UUID) throws {
        try store.write { tx in
            var block = try #require(try tx.block(blockId))
            block.text = text
            try tx.updateBlock(block)
        }
    }

    static func text(with dates: [DateMention], prefix: String = "Позвонить ") -> InlineText {
        var string = prefix
        var runs: [StyledRun] = []
        for date in dates {
            runs.append(StyledRun(start: (string as NSString).length, length: 1, style: .date(date)))
            string += "\u{FFFC} "
        }
        return InlineText(string, runs: runs)
    }

    func indexedIds() throws -> [UUID] {
        try index.allEntries().map(\.mentionId)
    }
}

/// Дата с напоминанием в `fireAt`.
func reminderDate(_ fireAt: Date, id: UUID = UUID()) -> DateMention {
    DateMention(id: id, start: "2026-10-20T09:00", includesTime: true, timeZone: "Europe/Moscow",
                reminder: DateMention.Reminder(fireAt: fireAt))
}

let referenceMoment = Date(timeIntervalSince1970: 1_792_400_000) // 2026-10-20, середина дня UTC

/// Что сообщил индекс подписчику, по порядку.
final class ChangeLog: Sendable {
    private let entries = Mutex<[ReminderIndexChange]>([])
    func append(_ change: ReminderIndexChange) { entries.withLock { $0.append(change) } }
    func withLock<T>(_ body: ([ReminderIndexChange]) -> T) -> T { entries.withLock { body($0) } }
}
