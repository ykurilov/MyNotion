import Foundation
import NotesCore

/// Снимок всех записей на момент `seq` (research R9): после него сервер сжимает журнал, новый Mac начинает с него.
/// Записи — те же изменения полей, что в пачках; `knowledge` — какие правки видел Mac, сделавший снимок.
public struct SyncSnapshot: Sendable, Hashable, Codable {
    public var formatVersion: Int
    public var seq: Int
    public var changes: [SyncChange]
    public var knowledge: ClockKnowledge

    public init(formatVersion: Int = SyncBatch.currentFormatVersion, seq: Int, changes: [SyncChange], knowledge: ClockKnowledge) {
        self.formatVersion = formatVersion
        self.seq = seq
        self.changes = changes
        self.knowledge = knowledge
    }

    /// Снять снимок базы: страницы, блоки (и пометки удалённых), надгробия.
    public static func make(seq: Int, from store: NotesStore) throws -> SyncSnapshot {
        try store.write { transaction in
            var changes: [SyncChange] = []
            var knowledge = ClockKnowledge()
            for page in try transaction.allPages() {
                let known = page.trashedAt == nil ? nil : try transaction.contentKnowledge(ofPage: page.id)
                changes += ChangeEncoding.fullPage(page, known: known)
                [page.fieldClocks.title, page.fieldClocks.icon, page.fieldClocks.placement, page.fieldClocks.trashedAt]
                    .compactMap { $0 }.forEach { knowledge.record($0) }
                for (block, isDeleted) in try transaction.blocks(ofPage: page.id, includingDeleted: true) {
                    changes += ChangeEncoding.fullBlock(block, baseHlc: nil)
                    if isDeleted, let deleted = block.fieldClocks.deleted {
                        changes.append(SyncChange(entity: .block, id: block.id, pageId: page.id, value: .deleted, hlc: deleted,
                                                  baseHlc: block.fieldClocks.text))
                    }
                    block.fieldClocks.all.forEach { knowledge.record($0) }
                }
            }
            for tombstone in try transaction.allTombstones() {
                changes.append(SyncChange(entity: .page, id: tombstone.pageId, value: .erased, hlc: tombstone.erasedAt,
                                          known: tombstone.known))
                knowledge.record(tombstone.erasedAt)
            }
            knowledge = ClockKnowledge(knowledge.latestByDevice.filter { $0.key != HybridTimestamp.distantPast.deviceId })
            return SyncSnapshot(seq: seq, changes: changes, knowledge: knowledge)
        }
    }
}

extension ClockKnowledge {
    init(_ latest: [UUID: HybridTimestamp]) {
        self.init(latestByDevice: latest)
    }
}
