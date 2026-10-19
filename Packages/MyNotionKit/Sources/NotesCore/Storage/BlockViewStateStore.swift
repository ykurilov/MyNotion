import Foundation
import GRDB

/// Вид блоков на этом Mac (data-model.md, «BlockViewState»): свёрнутые переключатели. Пишется сразу, мимо
/// транзакций `NotesStore`: без меток часов и подписчиков — в синхронизацию и отмену не попадает (research R1).
public struct BlockViewStateStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Свёрнутые блоки страницы; блоки, которых на странице нет, не возвращаются.
    public func collapsedBlockIds(ofPage pageId: UUID) throws -> Set<UUID> {
        try database.dbWriter.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT block_view_state.blockId FROM block_view_state JOIN block ON block.id = block_view_state.blockId
                WHERE block.pageId = ? AND block_view_state.isCollapsed = 1 AND block.isDeleted = 0
                """, arguments: [pageId.databaseText])
            return Set(ids.compactMap(UUID.init(uuidString:)))
        }
    }

    /// Свернуть или развернуть; развёрнутый — без строки.
    public func setCollapsed(_ collapsed: Bool, blockId: UUID) throws {
        try database.dbWriter.write { db in
            if collapsed {
                try db.execute(sql: "INSERT OR REPLACE INTO block_view_state (blockId, isCollapsed) VALUES (?, 1)",
                               arguments: [blockId.databaseText])
            } else {
                try db.execute(sql: "DELETE FROM block_view_state WHERE blockId = ?", arguments: [blockId.databaseText])
            }
        }
    }
}
