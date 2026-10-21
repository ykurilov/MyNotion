import Foundation
import GRDB
import NotesCore

/// Подписчик ядра: пересчитывает ссылки на файлы в той же транзакции, что `props` блока (data-model.md, «Attachment»).
/// Блок сослался на файл — пометка сироты снимается; файла на этом Mac нет (блок пришёл с другого Mac) — он встаёт
/// в очередь скачивания. Ни один живой блок не ссылается — `orphanedAt`: ⌘Z, корзина или возврат блока с другого Mac
/// снимут пометку, а через 30 дней сирота стирается (`AttachmentCollector`). Вернувшаяся копия этого Mac снова
/// встаёт в отправку: сервер мог уже убрать файл в корзину (contracts/sync-and-files-api.md, `DELETE`).
/// Ссылкой считается то же, что в `liveReference`: живой блок с файлами, а не любое описание файла в `props`.
public struct AttachmentReferenceCounter: NotesWriteHook {
    let now: @Sendable () -> Date
    /// Очередь файлов изменилась: появилось что отправить или скачать.
    let onQueueChange: @Sendable () -> Void

    public init(now: @escaping @Sendable () -> Date = { Date() }, onQueueChange: @escaping @Sendable () -> Void = {}) {
        self.now = now
        self.onQueueChange = onQueueChange
    }

    public func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        let db = transaction.database
        var referenced: [AttachmentRef] = []
        var mayHaveLostReferences = !changes.erasedPageIds.isEmpty
        // Обложка-файл страницы (003) — такая же ссылка на файл, как картинка в блоке.
        for change in changes.pages where change.isNew || change.changedFields.contains(.cover) {
            if let ref = change.page.cover?.attachment { referenced.append(ref) }
            if !change.isNew { mayHaveLostReferences = true }
        }
        for change in changes.blocks {
            switch change {
            case .saved(let block, let fields, let isNew):
                guard BlockKind.withAttachments.contains(block.kind) || fields.contains(.kindAndIndent) else { continue }
                guard isNew || !fields.isDisjoint(with: [.props, .deleted, .kindAndIndent]) else { continue }
                if BlockKind.withAttachments.contains(block.kind) { referenced += block.props.attachmentRefs }
                if !isNew { mayHaveLostReferences = true }
            case .erased:
                mayHaveLostReferences = true
            }
        }
        // Ячейки «Файлы и медиа» (004): файл из ячейки — такая же ссылка, как картинка в блоке.
        var kinds: [UUID: PropertyKind?] = [:]
        for cell in changes.database.cells {
            if kinds[cell.propertyId] == nil { kinds[cell.propertyId] = .some(try transaction.property(cell.propertyId)?.kind) }
            guard kinds[cell.propertyId] == .some(.files) else { continue }
            referenced += Self.attachmentRefs(inFilesValue: cell.value)
            mayHaveLostReferences = true
        }
        guard !referenced.isEmpty || mayHaveLostReferences else { return }

        var queueChanged = false
        for ref in referenced {
            // Файл с другого Mac: здесь его ещё нет — в очередь скачивания. Пока не скачан, запись следует за описанием
            // в блоке: другой Mac мог прислать блок раньше, чем докопировал файл и узнал его SHA-256. Так же — после
            // неудачного скачивания: повтор пойдёт уже по новому описанию.
            try db.execute(sql: """
                INSERT INTO attachment (id, ref, localPath, state) VALUES (?, ?, NULL, 'remote')
                ON CONFLICT(id) DO UPDATE SET ref = excluded.ref, state = 'remote'
                    WHERE attachment.ref != excluded.ref AND (attachment.state IN ('remote', 'downloading')
                        OR (attachment.state = 'failed' AND attachment.localPath IS NULL AND attachment.lastError IN (?, ?)))
                """, arguments: [ref.id.attachmentKey, AttachmentRecord.json(ref), AttachmentTransfer.downloadFailedMessage,
                                 AttachmentError.damaged.localizedDescription])
            queueChanged = queueChanged || db.changesCount > 0
            try db.execute(sql: """
                UPDATE attachment SET orphanedAt = NULL,
                    state = CASE WHEN state = 'uploaded' AND localPath IS NOT NULL THEN 'local' ELSE state END
                WHERE id = ? AND orphanedAt IS NOT NULL
                """, arguments: [ref.id.attachmentKey])
            queueChanged = queueChanged || db.changesCount > 0
        }
        if mayHaveLostReferences {
            try db.execute(sql: """
                UPDATE attachment SET orphanedAt = ? WHERE orphanedAt IS NULL AND NOT EXISTS (\(Self.liveReference))
                """, arguments: [now()])
        }
        if queueChanged {
            let onQueueChange = onQueueChange
            transaction.afterCommit { onQueueChange() }
        }
    }

    /// Живой блок, в `props` которого есть id файла (JSON пишет id заглавными буквами), или страница с этой обложкой.
    static let liveReference = """
        SELECT 1 FROM block WHERE block.isDeleted = 0
            AND block.kind IN (\(BlockKind.withAttachments.map { "'\($0.rawValue)'" }.sorted().joined(separator: ", ")))
            AND instr(upper(block.props), upper(attachment.id)) > 0
        UNION ALL SELECT 1 FROM page WHERE page.cover IS NOT NULL AND instr(upper(page.cover), upper(attachment.id)) > 0
        UNION ALL \(cellReference)
        """

    /// Ячейка «Файлы и медиа» с этим файлом — по индексу свойства, только у свойств-файлов.
    static let cellReference = """
        SELECT 1 FROM db_property p JOIN db_cell c ON c.propertyId = p.id
            WHERE p.type = 'files' AND c.value IS NOT NULL AND instr(upper(c.value), upper(attachment.id)) > 0
        """

    /// Файлы в значении ячейки: `[{attachment: AttachmentRef} | {url, name}]` (data-model.md, `db_cell.value`).
    public static func attachmentRefs(inFilesValue value: JSONValue?) -> [AttachmentRef] {
        (value?.array ?? []).compactMap { item in item["attachment"].flatMap { try? $0.decoded(as: AttachmentRef.self) } }
    }
}
