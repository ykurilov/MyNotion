import Foundation
import GRDB

/// Открытая транзакция записи. Живёт только внутри `NotesStore.write`.
public final class NotesTransaction {
    private let db: Database
    package let clock: HybridLogicalClock
    /// Что изменено в этой транзакции на данный момент.
    package private(set) var changes = NotesChanges()
    private var touchedPageIds: Set<UUID> = []
    private let keepsDeletionMarks: Bool

    init(db: Database, clock: HybridLogicalClock, keepsDeletionMarks: Bool = false) {
        self.db = db
        self.clock = clock
        self.keepsDeletionMarks = keepsDeletionMarks
    }

    /// Соединение этой транзакции — для таблиц модулей-добавок (синхронизация).
    package var database: Database { db }

    /// Выполнить после успешной фиксации транзакции (например, разбудить отправку).
    package func afterCommit(_ action: @escaping @Sendable () -> Void) {
        db.afterNextTransaction { _ in action() }
    }

    // MARK: Чтение внутри транзакции

    public func page(_ id: UUID) throws -> Page? {
        try Self.fetchPage(id, in: db)
    }

    public func blocks(ofPage pageId: UUID) throws -> [Block] {
        try Self.fetchBlocks(ofPage: pageId, in: db)
    }

    /// Блок как он лежит в базе сейчас; `nil`, если его нет.
    public func block(_ id: UUID) throws -> Block? {
        try storedBlock(id)
    }

    static func fetchPage(_ id: UUID, in db: Database) throws -> Page? {
        try Row.fetchOne(db, sql: "SELECT * FROM page WHERE id = ?", arguments: [id.databaseText]).map(Page.init(row:))
    }

    static func fetchBlocks(ofPage pageId: UUID, in db: Database) throws -> [Block] {
        let rows = try Row.fetchCursor(
            db,
            sql: "SELECT * FROM block WHERE pageId = ? AND isDeleted = 0 ORDER BY sortKey, id",
            arguments: [pageId.databaseText]
        )
        var columns: BlockColumns?
        var blocks: [Block] = []
        while let row = try rows.next() {
            let known = try columns ?? BlockColumns(row)
            columns = known
            blocks.append(try Block(row: row, columns: known))
        }
        return blocks
    }

    /// Контейнеры страницы под пометкой «удалён» и их контейнер.
    static func fetchRemovedContainers(ofPage pageId: UUID, in db: Database) throws -> [UUID: UUID?] {
        let kinds = BlockKind.allCases.filter(\.isContainer).map { "'\($0.rawValue)'" }.joined(separator: ", ")
        var result: [UUID: UUID?] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, containerId FROM block WHERE pageId = ? AND isDeleted = 1 AND kind IN (\(kinds))",
                                    arguments: [pageId.databaseText]) {
            guard let id = RowDecoding.optionalUUID(row, "id") else { continue }
            result[id] = .some(RowDecoding.optionalUUID(row, "containerId"))
        }
        return result
    }

    // MARK: Страницы

    /// Новая страница с одним пустым абзацем. Без `after` и `before` встаёт последней среди соседей.
    @discardableResult
    public func createPage(
        title: String = "",
        icon: String? = nil,
        parentId: UUID? = nil,
        after: FractionalSortKey? = nil,
        before: FractionalSortKey? = nil
    ) throws -> Page {
        let sortKey = if after == nil, before == nil {
            FractionalSortKey.between(try lastSiblingKey(parentId: parentId), nil)
        } else {
            FractionalSortKey.between(after, before)
        }
        let now = Date()
        var page = Page(title: title, icon: icon, parentId: parentId, sortKey: sortKey, createdAt: now, updatedAt: now)
        try insertPage(&page)
        try insertBlock(Block(pageId: page.id, sortKey: .between(nil, nil)))
        return page
    }

    /// Записать новую страницу; все поля получают одну метку часов.
    public func insertPage(_ page: inout Page) throws {
        try validate(page)
        page.fieldClocks.stamp(Set(Page.Field.allCases), with: clock.now())
        try page.insert(into: db)
        touchedPageIds.insert(page.id)
        changes.pages.append(PageChange(page: page, changedFields: Set(Page.Field.allCases), isNew: true))
    }

    /// Записать новую страницу; все поля получают одну метку часов.
    public func insertPage(_ page: Page) throws {
        var page = page
        try insertPage(&page)
    }

    /// Записать изменения страницы; новую метку получают только изменённые поля.
    @discardableResult
    public func updatePage(_ page: Page) throws -> Page {
        guard let stored = try self.page(page.id) else { throw NotesStoreError.pageNotFound(page.id) }
        let changedFields = page.changedFields(comparedTo: stored)
        guard !changedFields.isEmpty else { return stored }
        try validate(page)

        var updated = page
        updated.createdAt = stored.createdAt
        updated.fieldClocks = stored.fieldClocks
        updated.fieldClocks.stamp(changedFields, with: clock.now())
        // Избранное и недавние — порядок и вид, а не содержимое: «изменено» не трогают (data-model.md, «Page»).
        updated.updatedAt = changedFields.isSubset(of: Page.Field.bookkeeping) ? stored.updatedAt : Date()
        try updated.update(in: db)
        changes.pages.append(PageChange(page: updated, changedFields: changedFields, isNew: false))
        return updated
    }

    /// Стереть страницу навсегда вместе с её блоками; остаётся надгробие (id + метка часов).
    /// Подстраницы не трогаются — ветку стирает `PageTreeOperations`.
    public func erasePage(_ pageId: UUID) throws {
        guard try pageExists(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
        try erase(pageId, erasedAt: clock.now(), known: try contentKnowledge(ofPage: pageId))
    }

    /// Какие правки содержимого страницы (название, иконка, блоки, в том числе удалённые) есть на этом Mac.
    package func contentKnowledge(ofPage pageId: UUID) throws -> ClockKnowledge {
        var knowledge = ClockKnowledge()
        if let page = try page(pageId) {
            for stamp in [page.fieldClocks.title, page.fieldClocks.icon].compactMap({ $0 }) { knowledge.record(stamp) }
        }
        for (block, _) in try blocks(ofPage: pageId, includingDeleted: true) {
            for stamp in block.fieldClocks.all { knowledge.record(stamp) }
        }
        return knowledge
    }

    private func erase(_ pageId: UUID, erasedAt: HybridTimestamp, known: ClockKnowledge) throws {
        try db.execute(sql: "DELETE FROM block WHERE pageId = ?", arguments: [pageId.databaseText])
        try db.execute(sql: "DELETE FROM page WHERE id = ?", arguments: [pageId.databaseText])
        try db.execute(
            sql: "INSERT OR REPLACE INTO page_tombstone (pageId, erasedAt, knownClocks) VALUES (?, ?, ?)",
            arguments: [pageId.databaseText, erasedAt.description, try JSONColumn.encode(known)]
        )
        touchedPageIds.remove(pageId)
        changes.erasedPageIds.append(pageId)
    }

    /// Все страницы, включая корзину, без блоков.
    public func allPages() throws -> [Page] {
        try Row.fetchAll(db, sql: "SELECT * FROM page ORDER BY sortKey, id").map(Page.init(row:))
    }

    // MARK: Блоки

    /// Записать новый блок; все поля получают одну метку часов.
    @discardableResult
    public func insertBlock(_ block: Block) throws -> Block {
        guard try pageExists(block.pageId) else { throw NotesStoreError.pageNotFound(block.pageId) }
        try validate(block)
        var inserted = block
        let stamp = clock.now()
        let fields = Set(Block.Field.allCases).subtracting([.deleted])
        inserted.fieldClocks.stamp(fields, with: stamp)
        inserted.textBaseClock = stamp
        // Блок, оставшийся пометкой «удалён», возвращается под тем же id.
        try db.execute(sql: "DELETE FROM block WHERE id = ? AND isDeleted = 1", arguments: [block.id.databaseText])
        try inserted.insert(into: db)
        touchedPageIds.insert(block.pageId)
        changes.blocks.append(.saved(inserted, changedFields: fields, isNew: true))
        return inserted
    }

    /// Записать изменения блока; новую метку получают только изменённые поля.
    @discardableResult
    public func updateBlock(_ block: Block) throws -> Block {
        guard let stored = try storedBlock(block.id) else { throw NotesStoreError.blockNotFound(block.id) }
        guard stored.pageId == block.pageId else { throw NotesStoreError.invalidBlock("блок нельзя перенести на другую страницу") }
        let changedFields = block.changedFields(comparedTo: stored)
        guard !changedFields.isEmpty else { return stored }
        try validate(block)

        var updated = block
        updated.fieldClocks = stored.fieldClocks
        updated.fieldClocks.stamp(changedFields, with: clock.now())
        updated.textBaseClock = changedFields.contains(.text) ? updated.fieldClocks.text : stored.textBaseClock
        if changedFields.contains(.text), let base = stored.fieldClocks.text, changes.textBaseClocks[block.id] == nil {
            changes.textBaseClocks[block.id] = base
        }
        try updated.update(in: db)
        changes.blocks.append(.saved(updated, changedFields: changedFields, isNew: false))
        return updated
    }

    /// Удалить блок. Пока синхронизации нет, он стирается сразу; с ней — остаётся пометкой «удалён» с меткой часов,
    /// пока её не получат все устройства (data-model.md). Если на странице не останется блоков, в конце транзакции
    /// появится пустой абзац.
    public func deleteBlock(_ blockId: UUID) throws {
        guard var stored = try storedBlock(blockId) else { throw NotesStoreError.blockNotFound(blockId) }
        if keepsDeletionMarks {
            stored.fieldClocks.stamp([.deleted], with: clock.now())
            try stored.update(in: db)
            try db.execute(sql: "UPDATE block SET isDeleted = 1 WHERE id = ?", arguments: [blockId.databaseText])
        } else {
            try db.execute(sql: "DELETE FROM block WHERE id = ?", arguments: [blockId.databaseText])
        }
        touchedPageIds.insert(stored.pageId)
        changes.blocks.append(.erased(blockId: blockId, pageId: stored.pageId))
    }

    // MARK: Конфликты

    /// Записать конфликт текста блока. Если по блоку уже ждёт неразрешённый конфликт с той же второй версией,
    /// обновляется его своя версия (Юрий дописал блок); с другой второй версией — это новый конфликт,
    /// иначе одна из версий пропала бы.
    @discardableResult
    public func recordConflict(blockId: UUID, localVersion: InlineText, remoteVersion: InlineText,
                               remoteDeviceName: String) throws -> Conflict {
        if var pending = try pendingConflicts(ofBlock: blockId).last(where: { $0.remoteVersion == remoteVersion }) {
            pending.localVersion = localVersion
            pending.remoteVersion = remoteVersion
            pending.remoteDeviceName = remoteDeviceName
            try pending.update(in: db)
            return pending
        }
        let conflict = Conflict(blockId: blockId, localVersion: localVersion, remoteVersion: remoteVersion,
                                remoteDeviceName: remoteDeviceName)
        try conflict.insert(into: db)
        return conflict
    }

    /// Неразрешённые конфликты блока по времени появления.
    public func pendingConflicts(ofBlock blockId: UUID) throws -> [Conflict] {
        try Row.fetchAll(
            db, sql: "SELECT * FROM conflict WHERE blockId = ? AND resolvedAt IS NULL ORDER BY detectedAt, id",
            arguments: [blockId.databaseText]
        ).map(Conflict.init(row:))
    }

    /// Юрий выбрал версию: конфликт решён. Сам выбор — обычная правка текста блока.
    public func resolveConflict(_ conflictId: UUID) throws {
        guard var conflict = try Row.fetchOne(db, sql: "SELECT * FROM conflict WHERE id = ?", arguments: [conflictId.databaseText])
            .map(Conflict.init(row:)), conflict.resolvedAt == nil else { return }
        conflict.resolvedAt = Date()
        try conflict.update(in: db)
        changes.resolvedConflicts.append(conflict)
    }

    /// Записать конфликт, найденный при слиянии; такой же ожидающий второй раз не записывается.
    @discardableResult
    package func addConflict(blockId: UUID, shownVersion: InlineText, otherVersion: InlineText,
                             otherDeviceName: String) throws -> Bool {
        let pending = try pendingConflicts(ofBlock: blockId)
        guard !pending.contains(where: { $0.localVersion == shownVersion && $0.remoteVersion == otherVersion }) else { return false }
        try Conflict(blockId: blockId, localVersion: shownVersion, remoteVersion: otherVersion,
                     remoteDeviceName: otherDeviceName).insert(into: db)
        return true
    }

    /// Снять ожидающий конфликт без записи в изменения (его уже решили на другом Mac).
    package func markConflictResolved(_ conflict: Conflict) throws {
        var resolved = conflict
        resolved.resolvedAt = Date()
        try resolved.update(in: db)
    }

    // MARK: Правки с других Mac (модуль Sync)

    /// Блок как он лежит в базе, в том числе пометкой «удалён».
    package func block(_ id: UUID, includingDeleted: Bool) throws -> (block: Block, isDeleted: Bool)? {
        guard includingDeleted else { return try storedBlock(id).map { ($0, false) } }
        return try Row.fetchOne(db, sql: "SELECT * FROM block WHERE id = ?", arguments: [id.databaseText]).map { row in
            (try Block(row: row), row["isDeleted"] as Bool)
        }
    }

    package func blocks(ofPage pageId: UUID, includingDeleted: Bool) throws -> [(block: Block, isDeleted: Bool)] {
        guard includingDeleted else { return try blocks(ofPage: pageId).map { ($0, false) } }
        return try Row.fetchAll(db, sql: "SELECT * FROM block WHERE pageId = ? ORDER BY sortKey, id",
                                arguments: [pageId.databaseText]).map { row in (try Block(row: row), row["isDeleted"] as Bool) }
    }

    /// Записать страницу ровно такой, какой она пришла: со своими метками часов, без проверки петель —
    /// петли разбирает слияние.
    package func writeReplicatedPage(_ page: Page, changedFields: Set<Page.Field>) throws {
        if let icon = page.icon, !Self.isSingleEmoji(icon) {
            throw NotesStoreError.invalidPage("иконка — один эмодзи или пусто")
        }
        let isNew = try !pageExists(page.id)
        if isNew { try page.insert(into: db) } else { try page.update(in: db) }
        changes.pages.append(PageChange(page: page, changedFields: isNew ? Set(Page.Field.allCases) : changedFields, isNew: isNew))
    }

    /// Записать блок ровно таким, каким он пришёл, вместе с пометкой «удалён».
    package func writeReplicatedBlock(_ block: Block, isDeleted: Bool, changedFields: Set<Block.Field>) throws {
        try validate(block)
        let existing = try self.block(block.id, includingDeleted: true)
        if existing == nil { try block.insert(into: db) } else { try block.update(in: db) }
        try db.execute(sql: "UPDATE block SET isDeleted = ? WHERE id = ?", arguments: [isDeleted, block.id.databaseText])
        if isDeleted {
            if existing?.isDeleted == false { changes.blocks.append(.erased(blockId: block.id, pageId: block.pageId)) }
        } else {
            let appears = existing == nil || existing?.isDeleted == true
            changes.blocks.append(.saved(block, changedFields: appears ? Set(Block.Field.allCases) : changedFields, isNew: appears))
        }
    }

    /// Стереть страницу по правке с другого Mac: метка стирания и известные ему правки — оттуда.
    package func eraseReplicatedPage(_ pageId: UUID, erasedAt: HybridTimestamp, known: ClockKnowledge) throws {
        try erase(pageId, erasedAt: erasedAt, known: known)
    }

    /// Надгробие страницы: когда стёрта и какие правки видел стёрший Mac.
    package func tombstone(ofPage pageId: UUID) throws -> (erasedAt: HybridTimestamp, known: ClockKnowledge)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT erasedAt, knownClocks FROM page_tombstone WHERE pageId = ?",
                                         arguments: [pageId.databaseText]),
              let erasedAt = HybridTimestamp(row["erasedAt"] as String) else { return nil }
        return (erasedAt, try RowDecoding.json(ClockKnowledge.self, row, "knownClocks"))
    }

    package func allTombstones() throws -> [(pageId: UUID, erasedAt: HybridTimestamp, known: ClockKnowledge)] {
        try Row.fetchAll(db, sql: "SELECT pageId FROM page_tombstone ORDER BY erasedAt").compactMap { row in
            guard let pageId = RowDecoding.optionalUUID(row, "pageId"), let tombstone = try tombstone(ofPage: pageId) else { return nil }
            return (pageId, tombstone.erasedAt, tombstone.known)
        }
    }

    package func removeTombstone(ofPage pageId: UUID) throws {
        try db.execute(sql: "DELETE FROM page_tombstone WHERE pageId = ?", arguments: [pageId.databaseText])
    }

    /// Записать надгробие страницы, которой на этом Mac не было.
    package func writeTombstone(ofPage pageId: UUID, erasedAt: HybridTimestamp, known: ClockKnowledge) throws {
        if let existing = try tombstone(ofPage: pageId), existing.erasedAt >= erasedAt { return }
        try db.execute(sql: "INSERT OR REPLACE INTO page_tombstone (pageId, erasedAt, knownClocks) VALUES (?, ?, ?)",
                       arguments: [pageId.databaseText, erasedAt.description, try JSONColumn.encode(known)])
    }

    /// Новые метки всем полям страницы и её живых блоков: так этот Mac отправляет страницу целиком,
    /// и она перекрывает стирание на других Mac (research R8).
    package func restampPageWithBlocks(_ pageId: UUID) throws {
        guard var page = try page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
        page.fieldClocks.stamp(Set(Page.Field.allCases), with: clock.now())
        page.updatedAt = Date()
        try page.update(in: db)
        changes.pages.append(PageChange(page: page, changedFields: Set(Page.Field.allCases), isNew: true))
        for block in try blocks(ofPage: pageId) {
            try restampBlock(block)
        }
    }

    /// Новые метки всем полям живого блока: блок уходит на другие Mac целиком.
    package func restampBlock(_ blockId: UUID) throws {
        guard let block = try storedBlock(blockId) else { throw NotesStoreError.blockNotFound(blockId) }
        try restampBlock(block)
    }

    private func restampBlock(_ block: Block) throws {
        var restamped = block
        let fields = Set(Block.Field.allCases).subtracting([.deleted])
        restamped.fieldClocks.stamp(fields, with: clock.now())
        if let base = block.fieldClocks.text { changes.textBaseClocks[block.id] = base }
        restamped.textBaseClock = restamped.fieldClocks.text
        try restamped.update(in: db)
        changes.blocks.append(.saved(restamped, changedFields: fields, isNew: true))
    }

    /// Стереть пометки удалённых блоков и надгробия страниц: их получили все устройства или синхронизации нет.
    package func eraseDeletionMarksAndTombstones() throws {
        try db.execute(sql: "DELETE FROM block WHERE isDeleted = 1; DELETE FROM page_tombstone;")
    }

    // MARK: Напоминания

    package func reminderState(_ mentionId: UUID) throws -> ReminderState? {
        try Row.fetchOne(db, sql: "SELECT * FROM reminder_state WHERE mentionId = ?", arguments: [mentionId.databaseText])
            .flatMap(ReminderState.init(row:))
    }

    package func allReminderStates() throws -> [ReminderState] {
        try Row.fetchAll(db, sql: "SELECT * FROM reminder_state ORDER BY mentionId").compactMap(ReminderState.init(row:))
    }

    /// Записать отметку ровно такой, какой она пришла с другого Mac.
    package func writeReplicatedReminderState(_ state: ReminderState) throws {
        try saveReminderState(state)
    }

    /// Отметить напоминание сделанным (`doneAt`) или снова несделанным (`nil`) — на всех Mac (research R11).
    public func setReminderDone(_ mentionId: UUID, at doneAt: Date?) throws {
        try saveReminderState(ReminderState(mentionId: mentionId, doneAt: doneAt, doneClock: clock.now()))
    }

    private func saveReminderState(_ state: ReminderState) throws {
        try db.execute(sql: """
            INSERT INTO reminder_state (mentionId, doneAt, doneClock) VALUES (?, ?, ?)
            ON CONFLICT(mentionId) DO UPDATE SET doneAt = excluded.doneAt, doneClock = excluded.doneClock
            """, arguments: [state.mentionId.databaseText, state.doneAt, state.doneClock.description])
        changes.reminderStates.append(state)
    }

    // MARK: Подписчики

    /// Запрос подписчика в этой же транзакции (например, обновить индекс поиска).
    public func execute(sql: String, arguments: [SQLValue] = []) throws {
        try db.execute(sql: sql, arguments: StatementArguments(arguments.map(\.databaseValue)))
    }

    // MARK: Правила

    /// «У страницы всегда есть хотя бы один блок (пустой абзац)».
    func giveEveryTouchedPageABlock() throws {
        for pageId in touchedPageIds {
            let hasBlocks = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS (SELECT 1 FROM block WHERE pageId = ? AND isDeleted = 0)",
                arguments: [pageId.databaseText]
            ) ?? false
            if !hasBlocks, try pageExists(pageId) {
                try insertBlock(Block(pageId: pageId, sortKey: .between(nil, nil)))
            }
        }
        touchedPageIds.removeAll()
    }

    private func pageExists(_ id: UUID) throws -> Bool {
        try Bool.fetchOne(
            db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM page WHERE id = ?)"),
            arguments: [id.databaseText]
        ) ?? false
    }

    private func storedBlock(_ id: UUID) throws -> Block? {
        try Row.fetchOne(db, sql: "SELECT * FROM block WHERE id = ? AND isDeleted = 0", arguments: [id.databaseText])
            .map(Block.init(row:))
    }

    private func lastSiblingKey(parentId: UUID?) throws -> FractionalSortKey? {
        let raw = try String.fetchOne(
            db, sql: "SELECT MAX(sortKey) FROM page WHERE parentId IS ?", arguments: [parentId?.databaseText]
        )
        return raw.flatMap(FractionalSortKey.init(rawValue:))
    }

    private func validate(_ page: Page) throws {
        if let icon = page.icon, !Self.isSingleEmoji(icon) {
            throw NotesStoreError.invalidPage("иконка — один эмодзи или пусто")
        }
        var ancestorId = page.parentId
        var visited: Set<UUID> = []
        while let currentId = ancestorId {
            if currentId == page.id {
                throw NotesStoreError.invalidPage("страница не может лежать внутри себя или своей подстраницы")
            }
            guard visited.insert(currentId).inserted else { break }
            ancestorId = try String.fetchOne(db.cachedStatement(sql: "SELECT parentId FROM page WHERE id = ?"), arguments: [currentId.databaseText])
                .flatMap(UUID.init(uuidString:))
        }
    }

    private func validate(_ block: Block) throws {
        // Допустимая глубина зависит от соседей и решается при показе (`BlockNesting`); здесь — только пределы.
        guard Block.indentRange.contains(block.indent) else {
            throw NotesStoreError.invalidBlock("отступ — целое от 0 до 8")
        }
        if block.isChecked, block.kind != .checkbox {
            throw NotesStoreError.invalidBlock("отметка бывает только у чекбокса")
        }
        if (block.linkedPageId != nil) != (block.kind == .pageLink) {
            throw NotesStoreError.invalidBlock("ссылка на подстраницу бывает только у блока-подстраницы, и у него она обязательна")
        }
    }

    package static func isSingleEmoji(_ text: String) -> Bool {
        guard text.count == 1 else { return false }
        let scalars = text.unicodeScalars
        return scalars.contains { $0.properties.isEmojiPresentation } || scalars.contains("\u{FE0F}")
    }
}
