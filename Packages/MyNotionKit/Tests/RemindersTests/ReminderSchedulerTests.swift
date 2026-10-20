import Foundation
import Testing
@testable import NotesCore
@testable import Reminders

/// Планирование уведомлений с подменёнными часами и центром уведомлений (research R11, SC-104, tasks.md T056).
@MainActor
@Suite("Планирование напоминаний")
struct ReminderSchedulerTests {
    let library: ReminderLibrary
    let clock = TestClock(referenceMoment)
    let center = FakeNotificationCenter()
    let scheduler: ReminderScheduler

    init() throws {
        library = try ReminderLibrary()
        scheduler = ReminderScheduler(store: library.store, center: center, now: clock.reading)
    }

    @Test("Ставятся ближайшие 50 несделанных; идентификатор — id упоминания; повтор не дублирует")
    func nearestFiftyWithoutDuplicates() async throws {
        let dates = (1...60).map { reminderDate(referenceMoment.addingTimeInterval(Double($0) * 600)) }
        try library.page(dates: dates)
        try library.store.write { try $0.setReminderDone(dates[0].id, at: referenceMoment) }

        await scheduler.reschedule()
        await scheduler.reschedule()
        let expected = Set(dates[1...50].map { $0.id.uuidString.lowercased() })
        #expect(Set(center.pending.keys) == expected)
        #expect(center.delivered.isEmpty)
        let request = try #require(center.pending[dates[1].id.uuidString.lowercased()])
        #expect(request.fireAt == dates[1].reminder?.fireAt)
        #expect(request.title == "Дела")
        // Текст блока простым текстом (дата словами), обрезан до 100 знаков.
        #expect(request.body.hasPrefix("Позвонить @20 октября 2026, "))
        #expect(request.body.count == 100 && request.body.hasSuffix("…"))

        // Ближайшее сделали — в очередь встаёт 51-е.
        try library.store.write { try $0.setReminderDone(dates[1].id, at: referenceMoment) }
        await scheduler.reschedule()
        #expect(Set(center.pending.keys) == Set(dates[2...51].map { $0.id.uuidString.lowercased() }))
    }

    @Test("Система не приняла одно уведомление — остальные ставятся, показанные не показываются второй раз")
    func refusedNotificationDoesNotStopOthers() async throws {
        let overdue = (1...3).map { reminderDate(referenceMoment.addingTimeInterval(Double(-$0) * 600)) }
        let upcoming = (1...3).map { reminderDate(referenceMoment.addingTimeInterval(Double($0) * 600)) }
        try library.page(dates: overdue + upcoming)
        center.refused = [overdue[0].id.uuidString.lowercased(), upcoming[0].id.uuidString.lowercased()]

        await scheduler.reschedule()

        #expect(Set(center.pending.keys) == Set(upcoming[1...].map { $0.id.uuidString.lowercased() }))
        #expect(Set(center.shownCount.keys) == Set(overdue[1...].map { $0.id.uuidString.lowercased() }))
        await scheduler.reschedule()
        #expect(center.shownCount.values.allSatisfy { $0 == 1 }, "\(center.shownCount)")
    }

    @Test("Mac спал: после пробуждения просроченные за 7 дней показываются сразу и один раз")
    func catchUpAfterSleep() async throws {
        let soon = reminderDate(referenceMoment.addingTimeInterval(3600))
        let old = reminderDate(referenceMoment.addingTimeInterval(-8 * 24 * 3600))
        try library.page(dates: [soon, old])
        await scheduler.reschedule()
        #expect(Set(center.pending.keys) == [soon.id.uuidString.lowercased()])

        // Сон: время прошло, система уведомление не показала.
        clock.advance(by: 2 * 3600)
        await scheduler.reschedule()
        await scheduler.reschedule()
        let identifier = soon.id.uuidString.lowercased()
        #expect(center.shownCount[identifier] == 1)
        #expect(center.pending.isEmpty)
        // Старше 7 дней — не показывается.
        #expect(center.shownCount[old.id.uuidString.lowercased()] == nil)
    }

    @Test("Система показала в срок — после пробуждения второй раз не показывается")
    func noDuplicateAfterSystemDelivery() async throws {
        let soon = reminderDate(referenceMoment.addingTimeInterval(60))
        try library.page(dates: [soon])
        await scheduler.reschedule()
        clock.advance(by: 120)
        center.fireDue(at: clock.now)
        await scheduler.reschedule()
        #expect(center.shownCount[soon.id.uuidString.lowercased()] == 1)
    }

    @Test("Напоминание пришло с другого Mac уже просроченным — показывается сразу один раз")
    func overdueArrivalShownOnce() async throws {
        let missed = reminderDate(referenceMoment.addingTimeInterval(-600))
        try library.page(dates: [missed])
        await scheduler.reschedule()
        await scheduler.reschedule()
        #expect(center.shownCount[missed.id.uuidString.lowercased()] == 1)
    }

    @Test("doneAt снимает и показанное, и стоящее в очереди")
    func doneRemovesDeliveredAndPending() async throws {
        let shown = reminderDate(referenceMoment.addingTimeInterval(-60))
        let queued = reminderDate(referenceMoment.addingTimeInterval(600))
        try library.page(dates: [shown, queued])
        await scheduler.reschedule()
        #expect(center.delivered.keys.contains(shown.id.uuidString.lowercased()))
        #expect(center.pending.keys.contains(queued.id.uuidString.lowercased()))

        try library.store.write { tx in
            try tx.setReminderDone(shown.id, at: referenceMoment)
            try tx.setReminderDone(queued.id, at: referenceMoment)
        }
        let change = try #require(library.changes.withLock { $0.last })
        await scheduler.apply(change)
        #expect(center.delivered.isEmpty)
        #expect(center.pending.isEmpty)
    }

    @Test("Дата стёрта — уведомление уходит из очереди")
    func erasedDateLeavesQueue() async throws {
        let date = reminderDate(referenceMoment.addingTimeInterval(600))
        let ids = try library.page(dates: [date])
        await scheduler.reschedule()
        #expect(center.pending.count == 1)
        try library.setText(InlineText("Позвонить"), ofBlock: ids.block)
        await scheduler.reschedule()
        #expect(center.pending.isEmpty)
    }
}
