import Foundation
import GRDB
import Testing
@testable import NotesCore
@testable import Reminders

/// Индекс напоминаний обновляется в той же транзакции, что текст (research R11, tasks.md T055).
@Suite("Индекс напоминаний")
struct ReminderIndexTests {
    @Test("Дата с напоминанием попадает в индекс в той же транзакции, что текст; без напоминания — нет")
    func indexedInSameTransaction() throws {
        let library = try ReminderLibrary()
        let withReminder = reminderDate(referenceMoment)
        let plain = DateMention(start: "2026-10-21", includesTime: false, timeZone: "Europe/Moscow")
        let ids = try library.store.write { tx -> (page: UUID, block: UUID) in
            let page = try tx.createPage(title: "Дела")
            var block = try #require(try tx.blocks(ofPage: page.id).first)
            block.text = ReminderLibrary.text(with: [withReminder, plain])
            try tx.updateBlock(block)
            // Внутри той же транзакции индекс ещё не виден подписчику, но после фиксации — уже на месте.
            return (page.id, block.id)
        }
        let entries = try library.index.allEntries()
        #expect(entries.map(\.mentionId) == [withReminder.id])
        #expect(entries.first?.blockId == ids.block)
        #expect(entries.first?.pageId == ids.page)
        #expect(entries.first?.fireAt == referenceMoment)
    }

    @Test("Ошибка в транзакции — ни текста, ни строки индекса")
    func rolledBackTogether() throws {
        let library = try ReminderLibrary()
        let ids = try library.page(dates: [])
        struct Failure: Error {}
        #expect(throws: Failure.self) {
            try library.store.write { tx in
                var block = try #require(try tx.block(ids.block))
                block.text = ReminderLibrary.text(with: [reminderDate(referenceMoment)])
                try tx.updateBlock(block)
                throw Failure()
            }
        }
        #expect(try library.indexedIds().isEmpty)
    }

    @Test("Дата стёрта из текста — напоминание снято; сдвинуто время — строка с новым моментом")
    func erasedOrMovedDate() throws {
        let library = try ReminderLibrary()
        let first = reminderDate(referenceMoment)
        let second = reminderDate(referenceMoment.addingTimeInterval(3600))
        let ids = try library.page(dates: [first, second])
        #expect(Set(try library.indexedIds()) == [first.id, second.id])

        var moved = second
        moved.reminder = DateMention.Reminder(fireAt: referenceMoment.addingTimeInterval(7200))
        try library.setText(ReminderLibrary.text(with: [moved]), ofBlock: ids.block)
        let entries = try library.index.allEntries()
        #expect(entries.map(\.mentionId) == [second.id])
        #expect(entries.first?.fireAt == referenceMoment.addingTimeInterval(7200))
    }

    @Test("Блок удалён — напоминание снято; страница в корзине — снято, вернулась — снова стоит")
    @MainActor func deletedBlockAndTrash() throws {
        let library = try ReminderLibrary()
        let tree = PageTreeOperations(store: library.store)
        let parent = try library.page(title: "Родитель", dates: [reminderDate(referenceMoment)])
        let child = try library.page(title: "Дочь", dates: [reminderDate(referenceMoment)], parentId: parent.page)
        let other = try library.page(title: "Другая", dates: [reminderDate(referenceMoment)])
        #expect(try library.indexedIds().count == 3)

        try library.store.write { try $0.deleteBlock(other.block) }
        #expect(try library.index.allEntries().map(\.blockId).contains(other.block) == false)

        // В корзину — вместе с подстраницами.
        try tree.moveToTrash(parent.page)
        #expect(try library.indexedIds().isEmpty)
        try tree.restore(parent.page)
        #expect(Set(try library.index.allEntries().map(\.blockId)) == [parent.block, child.block])

        try tree.moveToTrash(parent.page)
        try tree.deleteForever(parent.page)
        #expect(try library.indexedIds().isEmpty)
    }

    @Test("Правка той же даты в другом месте текста не сбрасывает отметку показа; новое время — сбрасывает")
    func deliveredMarkSurvivesUnrelatedEdits() throws {
        let library = try ReminderLibrary()
        let date = reminderDate(referenceMoment)
        let ids = try library.page(dates: [date])
        try library.index.setDelivered([date.id], at: referenceMoment)

        try library.setText(ReminderLibrary.text(with: [date], prefix: "Позвонить маме "), ofBlock: ids.block)
        #expect(try library.index.allEntries().first?.deliveredAt == referenceMoment)

        var later = date
        later.reminder = DateMention.Reminder(fireAt: referenceMoment.addingTimeInterval(60))
        try library.setText(ReminderLibrary.text(with: [later]), ofBlock: ids.block)
        #expect(try library.index.allEntries().first?.deliveredAt == nil)
    }

    @Test("Дата удалена и возвращена с тем же id (⌘Z) — то же напоминание; копия с новым id — второе напоминание")
    func undoKeepsIdCopyGetsNewOne() throws {
        let library = try ReminderLibrary()
        let date = reminderDate(referenceMoment)
        let ids = try library.page(dates: [date])
        try library.setText(InlineText("Позвонить"), ofBlock: ids.block)
        #expect(try library.indexedIds().isEmpty)
        try library.setText(ReminderLibrary.text(with: [date]), ofBlock: ids.block)
        #expect(try library.indexedIds() == [date.id])

        var copy = date
        copy.id = UUID()
        try library.setText(ReminderLibrary.text(with: [date, copy]), ofBlock: ids.block)
        #expect(Set(try library.indexedIds()) == [date.id, copy.id])
    }

    @Test("Сделанные не активны; подписчик узнаёт о правке индекса и об отметке «сделано» после фиксации")
    func doneAndChangeNotices() throws {
        let library = try ReminderLibrary()
        let date = reminderDate(referenceMoment)
        try library.page(dates: [date])
        #expect(library.changes.withLock { $0.last }?.indexChanged == true)

        try library.store.write { try $0.setReminderDone(date.id, at: referenceMoment) }
        #expect(library.changes.withLock { $0.last }?.doneMentionIds == [date.id])
        #expect(try library.index.activeEntries().isEmpty)
        #expect(try library.index.doneMentionIds() == [date.id])

        try library.store.write { try $0.setReminderDone(date.id, at: nil) }
        #expect(try library.index.activeEntries().map(\.mentionId) == [date.id])
    }
}
