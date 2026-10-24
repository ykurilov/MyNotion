import Foundation
import GRDB
import Synchronization
import Testing
@testable import Databases
@testable import NotesCore
@testable import Reminders

/// Напоминания ячеек «Даты» (T066, research R16): момент срабатывания каждого варианта, уведомление с названием строки
/// и свойством, «сделано» — как у напоминаний 002 (одна отметка на все Mac). Часы подменены.
@MainActor
@Suite("Напоминания ячеек дат (US2)")
struct DatabaseReminderTests {
    let folder: URL
    let store: NotesStore
    let operations: DatabaseOperations
    let base: CreatedDatabase
    let row: UUID
    let due: DatabaseProperty

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dbrem-us2-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: folder.appendingPathComponent("MyNotion.sqlite")), clock: HybridLogicalClock(deviceId: UUID()))
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ReminderIndexer { _ in })
        operations = DatabaseOperations(store: store)
        base = try operations.createDatabase(in: nil, isInline: false, title: "Задачи")
        row = try operations.addRow(to: base.databaseId, in: base.viewId, at: .bottom, title: "Сдать отчёт")
        due = try operations.addProperty(to: base.databaseId, name: "Срок", kind: .date)
    }

    func moment(_ text: String) -> Date { DateText.parse(text, timeZone: "Europe/Moscow")! }

    @Test("Момент срабатывания — каждый вариант без времени и со временем", arguments: [
        ("2030-05-10", false, "day0At9", "2030-05-10T09:00"),
        ("2030-05-10", false, "day1", "2030-05-09T09:00"),
        ("2030-05-10", false, "day2", "2030-05-08T09:00"),
        ("2030-05-10", false, "week1", "2030-05-03T09:00"),
        ("2030-05-10T15:00", true, "atTime", "2030-05-10T15:00"),
        ("2030-05-10T15:00", true, "minutes5", "2030-05-10T14:55"),
        ("2030-05-10T15:00", true, "minutes10", "2030-05-10T14:50"),
        ("2030-05-10T15:00", true, "minutes15", "2030-05-10T14:45"),
        ("2030-05-10T15:00", true, "minutes30", "2030-05-10T14:30"),
        ("2030-05-10T15:00", true, "hour1", "2030-05-10T14:00"),
        ("2030-05-10T15:00", true, "hour2", "2030-05-10T13:00"),
        ("2030-05-10T15:00", true, "day1", "2030-05-09T15:00"),
        ("2030-05-10T15:00", true, "day2", "2030-05-08T15:00"),
    ])
    func fireMoment(start: String, hasTime: Bool, reminder: String, expected: String) throws {
        try operations.setCell(rowId: row, propertyId: due.id, value: ["start": .string(start), "hasTime": .bool(hasTime),
                                                                       "timeZone": "Europe/Moscow", "reminder": .string(reminder)])
        let entries = try ReminderIndex(store: store).allEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.fireAt == moment(expected))
        #expect(entries.first?.mentionId == CellReminder.mentionId(rowId: row, propertyId: due.id))
        #expect(DateReminder(rawValue: reminder) != nil, "вариант есть в окне")
    }

    @Test("Уведомление: название строки и «Свойство: дата»; щелчок ведёт к строке")
    func notificationContent() async throws {
        try operations.setCell(rowId: row, propertyId: due.id, value: ["start": "2030-05-10T15:00", "hasTime": true,
                                                                       "timeZone": "Europe/Moscow", "reminder": "minutes30"])
        let clock = Mutex(moment("2030-05-10T14:00"))
        let center = RecordingCenter()
        let scheduler = ReminderScheduler(store: store, center: center, now: { clock.withLock { $0 } })
        await scheduler.reschedule()
        let request = try #require(center.requests.first)
        #expect(request.title == "Сдать отчёт")
        #expect(request.body.hasPrefix("Срок: "))
        #expect(request.body.contains("15:00"))
        #expect(request.pageId == row)
        #expect(request.fireAt == moment("2030-05-10T14:30"))
    }

    @Test("«Сделано» — одна отметка: напоминание больше не ставится, отметка уходит в синхронизацию как у 002")
    func done() async throws {
        try operations.setCell(rowId: row, propertyId: due.id, value: ["start": "2030-05-10", "hasTime": false,
                                                                       "timeZone": "Europe/Moscow", "reminder": "day1"])
        let mention = CellReminder.mentionId(rowId: row, propertyId: due.id)
        var states: [ReminderState] = []
        try store.write { tx throws in
            try tx.setReminderDone(mention, at: moment("2030-05-09T09:05"))
            states = tx.changes.reminderStates
        }
        #expect(states.map(\.mentionId) == [mention])
        let index = ReminderIndex(store: store)
        #expect(try index.doneMentionIds() == [mention])
        #expect(try index.activeEntries().isEmpty)
        let center = RecordingCenter()
        await ReminderScheduler(store: store, center: center, now: { DateText.parse("2030-05-01", timeZone: "Europe/Moscow")! }).reschedule()
        #expect(center.requests.isEmpty)
    }

    @Test("Снять напоминание или очистить дату — из индекса уходит")
    func clear() throws {
        try operations.setCell(rowId: row, propertyId: due.id, value: ["start": "2030-05-10", "hasTime": false,
                                                                       "timeZone": "Europe/Moscow", "reminder": "day1"])
        try operations.setCell(rowId: row, propertyId: due.id, value: ["start": "2030-05-10", "hasTime": false, "timeZone": "Europe/Moscow"])
        #expect(try ReminderIndex(store: store).allEntries().isEmpty)
        try operations.setCell(rowId: row, propertyId: due.id, value: ["start": "2030-05-10", "hasTime": false,
                                                                       "timeZone": "Europe/Moscow", "reminder": "day1"])
        try operations.setCell(rowId: row, propertyId: due.id, value: nil)
        #expect(try ReminderIndex(store: store).allEntries().isEmpty)
    }
}

/// Центр уведомлений теста: только записывает, что поставлено.
final class RecordingCenter: ReminderNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var added: [ReminderNotificationRequest] = []
    var requests: [ReminderNotificationRequest] { lock.withLock { added } }

    func add(_ request: ReminderNotificationRequest) async throws { lock.withLock { added.append(request) } }
    func pendingIdentifiers() async -> [String] { lock.withLock { added.map(\.identifier) } }
    func removePending(_ identifiers: [String]) async {}
    func removeDelivered(_ identifiers: [String]) async {}
}
