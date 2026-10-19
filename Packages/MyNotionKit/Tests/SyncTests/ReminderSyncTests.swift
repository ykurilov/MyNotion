import Foundation
import Synchronization
import Testing
@testable import NotesCore
@testable import Reminders
@testable import Sync

/// Отметка «сделано» напоминания на двух Mac (research R11, tasks.md T057).
@MainActor
@Suite("Напоминания на двух Mac")
struct ReminderSyncTests {
    /// Центр уведомлений одного Mac: что стоит в очереди и что на экране.
    @MainActor
    final class Notifications: ReminderNotificationCenter {
        var pending: Set<String> = []
        var delivered: Set<String> = []

        nonisolated func add(_ request: ReminderNotificationRequest) async throws {
            await MainActor.run {
                if request.fireAt == nil { delivered.insert(request.identifier) } else { pending.insert(request.identifier) }
            }
        }
        nonisolated func pendingIdentifiers() async -> [String] { await MainActor.run { Array(pending) } }
        nonisolated func removePending(_ identifiers: [String]) async { await MainActor.run { pending.subtract(identifiers) } }
        nonisolated func removeDelivered(_ identifiers: [String]) async { await MainActor.run { delivered.subtract(identifiers) } }
    }

    /// Mac с индексом напоминаний и планировщиком; изменения индекса копятся до `settle`.
    @MainActor
    final class ReminderMac {
        let mac: SyncTestMac
        let notifications = Notifications()
        let scheduler: ReminderScheduler
        private let changes = ChangeBox()

        init(_ name: String, wallMillis: Int64, now: Date) throws {
            mac = try SyncTestMac(name: name, wallMillis: wallMillis)
            scheduler = ReminderScheduler(store: mac.store, center: notifications, now: { now })
            let changes = changes
            mac.store.addWriteHook(ReminderIndexer { change in changes.list.withLock { $0.append(change) } })
        }

        /// Отдать планировщику всё, что сообщил индекс.
        func settle() async {
            let pending = changes.list.withLock { list in defer { list.removeAll() }; return list }
            for change in pending { await scheduler.apply(change) }
        }
    }

    final class ChangeBox: Sendable {
        let list = Mutex<[ReminderIndexChange]>([])
    }

    let now = Date(timeIntervalSince1970: 1_792_400_000)

    @Test("«Готово» на одном Mac снимает уведомление на другом; doneAt сходится")
    func doneOnOneMacClearsOther() async throws {
        let numbering = TestJournalNumbering()
        let first = try ReminderMac("Mac 1", wallMillis: 1_000, now: now)
        let second = try ReminderMac("Mac 2", wallMillis: 2_000, now: now)
        let date = DateMention(start: "2026-10-20T09:00", includesTime: true, timeZone: "Europe/Moscow",
                               reminder: DateMention.Reminder(fireAt: now.addingTimeInterval(600)))
        let identifier = date.id.uuidString.lowercased()
        let ids = try sharedPage(on: first.mac, others: [second.mac], numbering: numbering)
        try first.mac.store.write { tx in
            var block = try #require(try tx.block(ids.block))
            block.text = InlineText("Позвонить \u{FFFC}", runs: [StyledRun(start: 10, length: 1, style: .date(date))])
            try tx.updateBlock(block)
        }
        try exchange([first.mac, second.mac], numbering: numbering)
        await first.settle()
        await second.settle()
        // Уведомление стоит на каждом Mac.
        #expect(first.notifications.pending == [identifier])
        #expect(second.notifications.pending == [identifier])

        try first.mac.store.write { try $0.setReminderDone(date.id, at: now) }
        try exchange([first.mac, second.mac], numbering: numbering)
        await first.settle()
        await second.settle()
        #expect(first.notifications.pending.isEmpty)
        #expect(second.notifications.pending.isEmpty)
        let states = try [first, second].map { mac in try mac.mac.store.write { try $0.reminderState(date.id) } }
        #expect(states[0]?.doneAt == now && states[0] == states[1])
    }

    @Test("Отметки с двух Mac в разном порядке сходятся к поздней")
    func doneAtConverges() async throws {
        let numbering = TestJournalNumbering()
        let first = try ReminderMac("Mac 1", wallMillis: 1_000, now: now)
        let second = try ReminderMac("Mac 2", wallMillis: 5_000, now: now)
        let mentionId = UUID()
        try first.mac.store.write { try $0.setReminderDone(mentionId, at: now) }
        // Второй Mac позже снял отметку, не видя первой.
        try second.mac.store.write { try $0.setReminderDone(mentionId, at: nil) }
        try exchange([first.mac, second.mac], numbering: numbering)
        let states = try [first, second].map { mac in try mac.mac.store.write { try $0.reminderState(mentionId) } }
        #expect(states[0] == states[1])
        #expect(states[0]?.doneAt == nil)
    }

    @Test("Включение синхронизации отправляет и отметки «сделано»")
    func enablingSyncSendsStates() throws {
        let mac = try SyncTestMac(name: "Mac", wallMillis: 1_000)
        let mentionId = UUID()
        try mac.store.write { tx in
            try tx.setReminderDone(mentionId, at: now)
            try Outbox.enqueueAllRecords(in: tx)
        }
        let sent = try mac.takeOutgoing().flatMap(\.changes).filter { $0.entity == .reminder }
        #expect(sent.map(\.id) == [mentionId, mentionId])
    }
}
