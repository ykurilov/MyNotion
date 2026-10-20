import Foundation
import GRDB
import NotesCore

/// Что поменялось в напоминаниях после записи: планировщик переставляет уведомления.
public struct ReminderIndexChange: Sendable, Hashable {
    /// Напоминания появились, пропали или сдвинулись.
    public var indexChanged: Bool
    /// Отмечены сделанными (здесь или на другом Mac): их уведомления снимаются.
    public var doneMentionIds: Set<UUID>

    public init(indexChanged: Bool = false, doneMentionIds: Set<UUID> = []) {
        self.indexChanged = indexChanged
        self.doneMentionIds = doneMentionIds
    }
}

/// Подписчик ядра: держит `reminder_index` в той же транзакции, что текст блоков (research R11), как поиск свой индекс.
/// В индексе только напоминания живых блоков страниц вне корзины; сделанность — в `reminder_state`.
/// Показ на этом Mac (`deliveredAt`) сохраняется, пока у напоминания тот же момент.
public struct ReminderIndexer: NotesWriteHook {
    let onChange: @Sendable (ReminderIndexChange) -> Void

    public init(onChange: @escaping @Sendable (ReminderIndexChange) -> Void = { _ in }) {
        self.onChange = onChange
    }

    public func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        let db = transaction.database
        var indexChanged = false
        var trashedCache: [UUID: Bool] = [:]
        func isInTrash(_ pageId: UUID) throws -> Bool {
            if let known = trashedCache[pageId] { return known }
            let value = try Self.isInTrash(pageId, in: db)
            trashedCache[pageId] = value
            return value
        }

        for change in changes.blocks {
            switch change {
            case .saved(let block, let fields, let isNew) where isNew || fields.contains(.text):
                let reminders = try isInTrash(block.pageId) ? [] : Self.reminders(in: block)
                indexChanged = try Self.replaceReminders(ofBlock: block.id, pageId: block.pageId, with: reminders, in: db) || indexChanged
            case .saved:
                break
            case .erased(let blockId, _):
                try db.execute(sql: "DELETE FROM reminder_index WHERE blockId = ?", arguments: [blockId.indexText])
                indexChanged = indexChanged || db.changesCount > 0
            }
        }
        for change in changes.pages where !change.isNew && change.changedFields.contains(.trashedAt) {
            trashedCache.removeAll()
            indexChanged = try reindexBranch(of: change.page.id, in: transaction) || indexChanged
        }
        for pageId in changes.erasedPageIds {
            try db.execute(sql: "DELETE FROM reminder_index WHERE pageId = ?", arguments: [pageId.indexText])
            indexChanged = indexChanged || db.changesCount > 0
        }

        let done = Set(changes.reminderStates.filter { $0.doneAt != nil }.map(\.mentionId))
        let undone = changes.reminderStates.contains { $0.doneAt == nil }
        guard indexChanged || !done.isEmpty || undone else { return }
        let change = ReminderIndexChange(indexChanged: indexChanged || undone, doneMentionIds: done)
        let onChange = onChange
        transaction.afterCommit { onChange(change) }
    }

    /// Даты с напоминанием в тексте блока.
    static func reminders(in block: Block) -> [(mentionId: UUID, fireAt: Date)] {
        let units = Array(block.text.string.utf16)
        return block.text.runs.compactMap { run in
            guard case .date(let date) = run.style, let reminder = date.reminder, run.length == 1, run.start < units.count,
                  units[run.start] == InlineText.objectReplacementCharacter else { return nil }
            return (date.id, reminder.fireAt)
        }
    }

    /// Строки индекса блока — ровно `reminders`. `true` — что-то поменялось.
    private static func replaceReminders(ofBlock blockId: UUID, pageId: UUID, with reminders: [(mentionId: UUID, fireAt: Date)],
                                         in db: Database) throws -> Bool {
        let kept = reminders.map(\.mentionId.indexText)
        let marks = kept.isEmpty ? "" : " AND mentionId NOT IN (\(Array(repeating: "?", count: kept.count).joined(separator: ", ")))"
        try db.execute(sql: "DELETE FROM reminder_index WHERE blockId = ?" + marks,
                       arguments: StatementArguments([blockId.indexText] + kept))
        var changed = db.changesCount > 0
        for reminder in reminders {
            let fireAt = ReminderIndex.storedMoment(reminder.fireAt)
            let current = try Row.fetchOne(db, sql: "SELECT blockId, pageId, fireAt FROM reminder_index WHERE mentionId = ?",
                                           arguments: [reminder.mentionId.indexText])
            if let current, current["blockId"] as String == blockId.indexText, current["pageId"] as String == pageId.indexText,
               current["fireAt"] as Date == fireAt { continue }
            try db.execute(sql: """
                INSERT INTO reminder_index (mentionId, pageId, blockId, fireAt, deliveredAt) VALUES (?, ?, ?, ?, NULL)
                ON CONFLICT(mentionId) DO UPDATE SET pageId = excluded.pageId, blockId = excluded.blockId, fireAt = excluded.fireAt,
                    deliveredAt = CASE WHEN reminder_index.fireAt = excluded.fireAt THEN reminder_index.deliveredAt ELSE NULL END
                """, arguments: [reminder.mentionId.indexText, pageId.indexText, blockId.indexText, fireAt])
            changed = true
        }
        return changed
    }

    /// Страницу убрали в корзину или вернули: напоминания её ветки сняты или поставлены заново.
    private func reindexBranch(of pageId: UUID, in transaction: NotesTransaction) throws -> Bool {
        let db = transaction.database
        let branch = try String.fetchAll(db, sql: """
            WITH RECURSIVE branch(id) AS (SELECT ? UNION ALL SELECT page.id FROM page JOIN branch ON page.parentId = branch.id)
            SELECT id FROM branch
            """, arguments: [pageId.indexText])
        let marks = Array(repeating: "?", count: branch.count).joined(separator: ", ")
        try db.execute(sql: "DELETE FROM reminder_index WHERE pageId IN (\(marks))", arguments: StatementArguments(branch))
        var changed = db.changesCount > 0
        guard try !Self.isInTrash(pageId, in: db) else { return changed }
        // Блоки с напоминанием находятся по записи оформления, не разбирая все блоки ветки.
        let blockIds = try String.fetchAll(db, sql: """
            SELECT id FROM block WHERE pageId IN (\(marks)) AND isDeleted = 0 AND textStyles LIKE '%"reminder"%'
            """, arguments: StatementArguments(branch))
        for id in blockIds.compactMap(UUID.init(uuidString:)) {
            guard let block = try transaction.block(id) else { continue }
            changed = try Self.replaceReminders(ofBlock: block.id, pageId: block.pageId, with: Self.reminders(in: block), in: db) || changed
        }
        return changed
    }

    /// Страница или кто-то из её предков в корзине.
    static func isInTrash(_ pageId: UUID, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            WITH RECURSIVE up(id, parentId, trashedAt) AS (
                SELECT id, parentId, trashedAt FROM page WHERE id = ?
                UNION ALL SELECT page.id, page.parentId, page.trashedAt FROM page JOIN up ON page.id = up.parentId)
            SELECT EXISTS (SELECT 1 FROM up WHERE trashedAt IS NOT NULL)
            """, arguments: [pageId.indexText]) ?? false
    }
}

extension UUID {
    /// Как id лежат в базе: строка UUID в нижнем регистре.
    var indexText: String { uuidString.lowercased() }
}
