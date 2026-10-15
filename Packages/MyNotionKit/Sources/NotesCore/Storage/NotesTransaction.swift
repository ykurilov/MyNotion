import Foundation
import GRDB

/// Открытая транзакция записи. Живёт только внутри `NotesStore.write`.
public final class NotesTransaction {
    private let db: Database
    private let clock: HybridLogicalClock
    private(set) var changes = NotesChanges()
    private var touchedPageIds: Set<UUID> = []

    init(db: Database, clock: HybridLogicalClock) {
        self.db = db
        self.clock = clock
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
        try Row.fetchAll(
            db,
            sql: "SELECT * FROM block WHERE pageId = ? AND isDeleted = 0 ORDER BY sortKey, id",
            arguments: [pageId.databaseText]
        ).map(Block.init(row:))
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
        updated.updatedAt = Date()
        try updated.update(in: db)
        changes.pages.append(PageChange(page: updated, changedFields: changedFields, isNew: false))
        return updated
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
        try updated.update(in: db)
        changes.blocks.append(.saved(updated, changedFields: changedFields, isNew: false))
        return updated
    }

    /// Удалить блок. Пока синхронизации нет, он стирается сразу (data-model.md).
    /// Если на странице не останется блоков, в конце транзакции появится пустой абзац.
    public func deleteBlock(_ blockId: UUID) throws {
        guard let stored = try storedBlock(blockId) else { throw NotesStoreError.blockNotFound(blockId) }
        try db.execute(sql: "DELETE FROM block WHERE id = ?", arguments: [blockId.databaseText])
        touchedPageIds.insert(stored.pageId)
        changes.blocks.append(.erased(blockId: blockId, pageId: stored.pageId))
    }

    // MARK: Конфликты

    /// Записать конфликт текста блока. Если по блоку уже ждёт неразрешённый конфликт,
    /// обновляется его своя версия: на один блок — одно ожидающее решение.
    @discardableResult
    public func recordConflict(blockId: UUID, localVersion: InlineText, remoteVersion: InlineText,
                               remoteDeviceName: String) throws -> Conflict {
        if var pending = try Row.fetchOne(
            db, sql: "SELECT * FROM conflict WHERE blockId = ? AND resolvedAt IS NULL ORDER BY detectedAt DESC LIMIT 1",
            arguments: [blockId.databaseText]
        ).map(Conflict.init(row:)) {
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
        guard Block.indentRange.contains(block.indent) else {
            throw NotesStoreError.invalidBlock("отступ — целое от 0 до 8")
        }
        if block.kind.isHeading, block.indent != 0 {
            throw NotesStoreError.invalidBlock("у заголовка отступа нет")
        }
        if block.isChecked, block.kind != .checkbox {
            throw NotesStoreError.invalidBlock("отметка бывает только у чекбокса")
        }
        if (block.linkedPageId != nil) != (block.kind == .pageLink) {
            throw NotesStoreError.invalidBlock("ссылка на подстраницу бывает только у блока-подстраницы, и у него она обязательна")
        }
    }

    static func isSingleEmoji(_ text: String) -> Bool {
        guard text.count == 1 else { return false }
        let scalars = text.unicodeScalars
        return scalars.contains { $0.properties.isEmojiPresentation } || scalars.contains("\u{FE0F}")
    }
}
