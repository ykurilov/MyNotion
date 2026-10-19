import Foundation

/// Накопленные правки документа на момент записи.
struct PageDocumentChanges {
    /// Новое название, если менялось.
    var title: String?
    /// Новые и изменённые блоки: текущая версия и та, что была записана (у нового — `nil`).
    var upserted: [(current: Block, saved: Block?)]
    var removedBlockIds: Set<UUID>

    var isEmpty: Bool { title == nil && upserted.isEmpty && removedBlockIds.isEmpty }
}

struct PageDocumentWriteResult {
    var page: Page?
    /// Как блоки легли в базу после записи.
    var blocks: [UUID: Block] = [:]
    /// Блоки, чей текст ушёл в конфликт, а не в базу.
    var conflictedBlockIds: Set<UUID> = []
}

/// Запись правок документа одной транзакцией (research R4): в базу идут только поля, изменённые
/// в документе, поверх того, что в базе сейчас. Текст, который в базе новее версии начала правки,
/// не затирается: обе версии сохраняются конфликтом (research R8).
enum PageDocumentWriter {
    static func write(_ changes: PageDocumentChanges, pageId: UUID, in transaction: NotesTransaction) throws -> PageDocumentWriteResult {
        var result = PageDocumentWriteResult()

        if let title = changes.title {
            guard var stored = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            stored.title = title
            result.page = try transaction.updatePage(stored)
        }

        for blockId in changes.removedBlockIds where try transaction.block(blockId) != nil {
            try transaction.deleteBlock(blockId)
        }

        for (current, saved) in changes.upserted {
            guard let saved, let stored = try transaction.block(current.id) else {
                // Новый блок — или блок, который успели стереть в базе: правка возвращает его целиком.
                result.blocks[current.id] = try transaction.insertBlock(current)
                continue
            }

            var merged = stored
            let edited = current.changedFields(comparedTo: saved)
            if edited.contains(.kindAndIndent) {
                merged.kind = current.kind
                merged.indent = current.indent
                merged.linkedPageId = current.linkedPageId
            }
            if edited.contains(.isChecked) || edited.contains(.kindAndIndent) {
                merged.isChecked = current.isChecked
            }
            if edited.contains(.placement) {
                merged.sortKey = current.sortKey
                merged.containerId = current.containerId
            }
            if edited.contains(.color) { merged.color = current.color }
            if edited.contains(.props) { merged.props = current.props }
            if edited.contains(.text) {
                if stored.fieldClocks.text == current.textBaseClock {
                    merged.text = current.text
                } else {
                    try transaction.recordConflict(
                        blockId: current.id,
                        localVersion: current.text,
                        remoteVersion: stored.text,
                        remoteDeviceName: stored.fieldClocks.text?.deviceId.uuidString ?? ""
                    )
                    result.conflictedBlockIds.insert(current.id)
                }
            }
            result.blocks[current.id] = try transaction.updateBlock(merged)
        }
        return result
    }
}
