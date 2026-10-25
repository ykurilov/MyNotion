import Foundation
import GRDB
import NotesCore

/// Запись очереди исходящих (data-model.md, «OutboxEntry»): одна будущая пачка.
public struct OutboxEntry: Sendable, Hashable {
    public let id: UUID
    public let createdAt: Date
    public let changes: [SyncChange]
}

/// Очередь исходящих изменений. Изменения кладёт подписчик ядра в той же транзакции, что и сама правка,
/// поэтому правка без записи в очереди не бывает (research R4, FR-020).
public struct Outbox: Sendable {
    public let store: NotesStore

    /// После фиксации транзакции, положившей что-то в очередь: пора отправлять.
    public static let didEnqueue = Notification.Name("Outbox.didEnqueue")
    /// Пачка не больше этого размера JSON: после шифрования и base64 она с запасом меньше 4 МБ сервера.
    static let maximumChunkBytes = 1_500_000

    public init(store: NotesStore) {
        self.store = store
    }

    /// Подписать очередь на записи хранилища. Пока синхронизация не включена, подписчик ничего не пишет.
    public static func install(on store: NotesStore) {
        store.addWriteHook(OutboxRecorder())
    }

    public func pendingEntries(limit: Int? = nil) throws -> [OutboxEntry] {
        try store.database.dbWriter.read { db in
            let sql = "SELECT * FROM outbox_entry ORDER BY createdAt, rowid" + (limit.map { " LIMIT \($0)" } ?? "")
            return try Row.fetchAll(db, sql: sql).map { row in
                let payload: Data = row["payload"]
                return OutboxEntry(id: UUID(uuidString: row["id"])!, createdAt: row["createdAt"],
                                   changes: try SyncJSON.decoder().decode([SyncChange].self, from: payload))
            }
        }
    }

    public func isEmpty() throws -> Bool {
        try store.database.dbWriter.read { try Self.isEmpty(in: $0) }
    }

    static func isEmpty(in db: Database) throws -> Bool {
        try !(Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM outbox_entry)") ?? false)
    }

    /// Пачку приняли на сервере — из очереди её можно убрать.
    public func remove(_ id: UUID) throws {
        try store.database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM outbox_entry WHERE id = ?", arguments: [id.uuidString.lowercased()])
        }
    }

    /// Положить изменения в очередь: пачками не больше `maximumChunkBytes`, поля одной записи — в одной пачке.
    static func enqueue(_ changes: [SyncChange], in db: Database) throws {
        guard !changes.isEmpty else { return }
        let encoder = SyncJSON.encoder()
        var chunks: [[SyncChange]] = [[]]
        var chunkBytes = 0
        for group in groupedByRecord(changes) {
            let bytes = try group.reduce(0) { $0 + (try encoder.encode($1).count) }
            if chunkBytes + bytes > maximumChunkBytes, !chunks[chunks.count - 1].isEmpty {
                chunks.append([])
                chunkBytes = 0
            }
            chunks[chunks.count - 1] += group
            chunkBytes += bytes
        }
        let now = Date()
        for chunk in chunks where !chunk.isEmpty {
            try db.execute(sql: "INSERT INTO outbox_entry (id, createdAt, payload) VALUES (?, ?, ?)",
                           arguments: [UUID.timeOrdered().uuidString.lowercased(), now, try encoder.encode(chunk)])
        }
    }

    /// Изменения подряд по записям, в порядке первого появления записи.
    static func groupedByRecord(_ changes: [SyncChange]) -> [[SyncChange]] {
        var order: [String] = []
        var groups: [String: [SyncChange]] = [:]
        for change in changes {
            let key = "\(change.entity.rawValue):\(change.id)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(change)
        }
        return order.map { groups[$0]! }
    }

    /// Всё, что уже есть в базе, — в очередь: при включении синхронизации записи этого Mac уходят на другие.
    static func enqueueAllRecords(in transaction: NotesTransaction) throws {
        var changes: [SyncChange] = []
        for page in try transaction.allPages() {
            changes += ChangeEncoding.fullPage(page)
            for block in try transaction.blocks(ofPage: page.id) {
                changes += ChangeEncoding.fullBlock(block, baseHlc: nil)
            }
        }
        changes += try DatabaseChangeEncoding.fullRecords(in: transaction)
        changes += try transaction.allReminderStates().map(ChangeEncoding.reminderChange)
        for row in try Row.fetchAll(transaction.database, sql: "SELECT pageId FROM page_tombstone") {
            guard let pageId = UUID(uuidString: row["pageId"]),
                  let tombstone = try transaction.tombstone(ofPage: pageId) else { continue }
            changes.append(SyncChange(entity: .page, id: pageId, value: .erased, hlc: tombstone.erasedAt, known: tombstone.known))
        }
        try enqueue(changes, in: transaction.database)
    }
}

/// Подписчик ядра: переводит изменения транзакции в изменения полей для других Mac.
/// Берёт только поля с метками этого Mac: правки, пришедшие с других, обратно не уходят.
struct OutboxRecorder: NotesWriteHook {
    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        guard try SyncAccountStore.isEnabled(in: transaction.database) else { return }
        let outgoing = try ChangeEncoding.outgoing(changes, in: transaction)
        guard !outgoing.isEmpty else { return }
        try Outbox.enqueue(outgoing, in: transaction.database)
        // Не дожидаясь главного потока: его подписчик (`queue: .main`) держал бы поток записи, пока главный, в свою
        // очередь, ждёт запись (копия ветки с очереди записи при включённой синхронизации — взаимная блокировка).
        transaction.afterCommit { DispatchQueue.main.async { NotificationCenter.default.post(name: Outbox.didEnqueue, object: nil) } }
    }
}

/// Перевод записей ядра в изменения полей (contracts/sync-api.md).
enum ChangeEncoding {
    static func outgoing(_ changes: NotesChanges, in transaction: NotesTransaction) throws -> [SyncChange] {
        let mine = transaction.clock.deviceId
        var result: [SyncChange] = []
        func isMine(_ stamp: HybridTimestamp?) -> Bool { stamp?.deviceId == mine }

        for change in changes.pages {
            let page = change.page
            for field in Page.Field.allCases where change.changedFields.contains(field) {
                guard let stamp = page.fieldClocks[field], isMine(stamp) else { continue }
                var encoded = pageChange(page, field: field, hlc: stamp)
                if field == .trashedAt, page.trashedAt != nil {
                    encoded.known = try transaction.contentKnowledge(ofPage: page.id)
                }
                result.append(encoded)
            }
        }
        for change in changes.blocks {
            switch change {
            case .saved(let block, let fields, _):
                for field in Block.Field.allCases where fields.contains(field) && field != .deleted {
                    guard let stamp = block.fieldClocks[field], isMine(stamp) else { continue }
                    result.append(blockChange(block, field: field, hlc: stamp,
                                              baseHlc: field == .text ? changes.textBaseClocks[block.id] : nil))
                }
            case .erased(let blockId, let pageId):
                guard let (block, isDeleted) = try transaction.block(blockId, includingDeleted: true), isDeleted,
                      let stamp = block.fieldClocks.deleted, isMine(stamp) else { continue }
                result.append(SyncChange(entity: .block, id: blockId, pageId: pageId, value: .deleted, hlc: stamp,
                                         baseHlc: block.fieldClocks.text))
            }
        }
        for pageId in changes.erasedPageIds {
            guard let tombstone = try transaction.tombstone(ofPage: pageId), isMine(tombstone.erasedAt) else { continue }
            result.append(SyncChange(entity: .page, id: pageId, value: .erased, hlc: tombstone.erasedAt, known: tombstone.known))
        }
        result += try DatabaseChangeEncoding.outgoing(changes.database, in: transaction)
        for state in changes.reminderStates where isMine(state.doneClock) {
            result.append(reminderChange(state))
        }
        for conflict in changes.resolvedConflicts {
            result.append(SyncChange(entity: .block, id: conflict.blockId,
                                     value: .conflictResolved(versions: [conflict.localVersion, conflict.remoteVersion]),
                                     hlc: transaction.clock.now()))
        }
        return deduplicated(result)
    }

    /// Одно поле записи правили в транзакции несколько раз — уходит последнее значение. Ячейки строки — разные
    /// записи с одним id: их различает свойство.
    private static func deduplicated(_ changes: [SyncChange]) -> [SyncChange] {
        func key(_ change: SyncChange) -> String {
            var key = "\(change.entity.rawValue):\(change.id):\(change.value.field)"
            if change.entity == .cell, case .databaseField(_, let value) = change.value { key += ":\(value["propertyId"]?.string ?? "")" }
            return key
        }
        var lastIndex: [String: Int] = [:]
        for (index, change) in changes.enumerated() where change.value.field != "conflictResolved" {
            lastIndex[key(change)] = index
        }
        return changes.enumerated().compactMap { index, change in
            guard change.value.field != "conflictResolved" else { return change }
            return lastIndex[key(change)] == index ? change : nil
        }
    }

    /// Отметка «сделано» напоминания (contracts/sync-and-files-api.md, «Новая сущность reminder»).
    static func reminderChange(_ state: ReminderState) -> SyncChange {
        SyncChange(entity: .reminder, id: state.mentionId, value: .doneAt(state.doneAt), hlc: state.doneClock)
    }

    static func pageChange(_ page: Page, field: Page.Field, hlc: HybridTimestamp) -> SyncChange {
        let value: SyncChange.Value = switch field {
        case .title: .title(page.title)
        case .icon: .icon(page.icon)
        case .placement: .placement(parentId: page.parentId, sortKey: page.sortKey.rawValue)
        case .trashedAt: .trashedAt(page.trashedAt)
        case .cover: .cover(page.cover)
        case .isFullWidth: .isFullWidth(page.isFullWidth)
        case .isSmallText: .isSmallText(page.isSmallText)
        case .favorite: .favorite(page.favorite?.rawValue)
        case .visitedAt: .visitedAt(page.visitedAt)
        case .isTemplate: .isTemplate(page.isTemplate)
        }
        return SyncChange(entity: .page, id: page.id, value: value, hlc: hlc, createdAt: field == .placement ? page.createdAt : nil)
    }

    static func blockChange(_ block: Block, field: Block.Field, hlc: HybridTimestamp, baseHlc: HybridTimestamp?) -> SyncChange {
        let value: SyncChange.Value = switch field {
        case .kindAndIndent: .kindAndIndent(kind: block.kind, indent: block.indent, linkedPageId: block.linkedPageId)
        case .text: .text(block.text)
        case .isChecked: .isChecked(block.isChecked)
        case .placement: .blockPlacement(containerId: block.containerId, sortKey: block.sortKey.rawValue)
        case .color: .color(block.color)
        case .props: .props(block.props)
        case .deleted: .deleted
        }
        return SyncChange(entity: .block, id: block.id, pageId: block.pageId, value: value, hlc: hlc, baseHlc: baseHlc)
    }

    /// Страница целиком: все поля с их метками (поле без меток — с самой ранней).
    static func fullPage(_ page: Page, known: ClockKnowledge? = nil) -> [SyncChange] {
        Page.Field.allCases.map { field in
            var change = pageChange(page, field: field, hlc: page.fieldClocks[field] ?? .distantPast)
            if field == .trashedAt, page.trashedAt != nil { change.known = known }
            return change
        }
    }

    static func fullBlock(_ block: Block, baseHlc: HybridTimestamp?) -> [SyncChange] {
        [Block.Field.kindAndIndent, .text, .isChecked, .placement, .color, .props].map { field in
            blockChange(block, field: field, hlc: block.fieldClocks[field] ?? .distantPast, baseHlc: field == .text ? baseHlc : nil)
        }
    }
}

extension BlockFieldClocks {
    subscript(field: Block.Field) -> HybridTimestamp? {
        switch field {
        case .kindAndIndent: kindAndIndent
        case .text: text
        case .isChecked: isChecked
        case .placement: placement
        case .color: color
        case .props: props
        case .deleted: deleted
        }
    }
}
