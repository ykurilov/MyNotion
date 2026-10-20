import Foundation
import GRDB

// Перевод записей в строки таблиц и обратно. id хранятся строками UUID в нижнем регистре,
// метки часов — строками HybridTimestamp, наборы меток и оформление — JSON.

extension UUID {
    var databaseText: String { uuidString.lowercased() }
}

enum RowDecoding {
    static func uuid(_ row: Row, _ column: String) throws -> UUID {
        guard let uuid = optionalUUID(row, column) else {
            throw NotesStoreError.corruptedRecord("Колонка \(column) — не UUID")
        }
        return uuid
    }

    static func optionalUUID(_ row: Row, _ column: String) -> UUID? {
        (row[column] as String?).flatMap(UUID.init(uuidString:))
    }

    static func sortKey(_ row: Row) throws -> FractionalSortKey {
        guard let key = FractionalSortKey(rawValue: row["sortKey"]) else {
            throw NotesStoreError.corruptedRecord("Колонка sortKey — не ключ порядка")
        }
        return key
    }

    static func json<T: Decodable>(_ type: T.Type, _ row: Row, _ column: String) throws -> T {
        let text: String = row[column]
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

enum JSONColumn {
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// Набор меток полей: `{"поле":"метка",…}` по алфавиту. Пишется на каждую запись,
    /// поэтому собирается вручную, без JSONEncoder (эталон — 100 000 блоков).
    static func encodeClocks(_ clocks: [(field: String, stamp: HybridTimestamp?)]) -> String {
        let pairs = clocks
            .compactMap { field, stamp in stamp.map { (field, $0) } }
            .sorted { $0.0 < $1.0 }
            .map { "\"\($0.0)\":\"\($0.1.description)\"" }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    static func encodeRuns(_ runs: [StyledRun]) throws -> String {
        runs.isEmpty ? "[]" : try encode(runs)
    }

    /// Цвет блока: `NULL`, если его нет.
    static func encodeColor(_ color: BlockColor) throws -> String? {
        color.isNone ? nil : try encode(color)
    }

    static func encodeProps(_ props: BlockProps) throws -> String {
        props.isEmpty ? "{}" : try encode(props)
    }
}

extension PageFieldClocks {
    var databaseJSON: String {
        JSONColumn.encodeClocks([("title", title), ("icon", icon), ("placement", placement), ("trashedAt", trashedAt),
                                 ("cover", cover), ("isFullWidth", isFullWidth), ("isSmallText", isSmallText), ("favorite", favorite),
                                 ("visitedAt", visitedAt), ("isTemplate", isTemplate)])
    }
}

extension BlockFieldClocks {
    var databaseJSON: String {
        JSONColumn.encodeClocks([("kindAndIndent", kindAndIndent), ("text", text), ("isChecked", isChecked),
                                 ("placement", placement), ("color", color), ("props", props), ("deleted", deleted)])
    }
}

extension Page {
    init(row: Row) throws {
        self.init(
            id: try RowDecoding.uuid(row, "id"),
            title: row["title"],
            icon: row["icon"],
            parentId: RowDecoding.optionalUUID(row, "parentId"),
            sortKey: try RowDecoding.sortKey(row),
            trashedAt: row["trashedAt"],
            createdAt: row["createdAt"],
            updatedAt: row["updatedAt"],
            cover: try (row["cover"] as String?).map { try JSONDecoder().decode(PageCover.self, from: Data($0.utf8)) },
            isFullWidth: row["isFullWidth"],
            isSmallText: row["isSmallText"],
            favorite: (row["favorite"] as String?).flatMap(FractionalSortKey.init(rawValue:)),
            visitedAt: row["visitedAt"],
            isTemplate: row["isTemplate"],
            fieldClocks: try RowDecoding.json(PageFieldClocks.self, row, "fieldClocks")
        )
    }

    func insert(into db: Database) throws {
        try db.cachedStatement(
            sql: """
                INSERT INTO page (id, title, icon, parentId, sortKey, trashedAt, createdAt, updatedAt, cover, isFullWidth, isSmallText,
                                  favorite, visitedAt, isTemplate, fieldClocks)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
        ).execute(arguments: [id.databaseText, title, icon, parentId?.databaseText, sortKey.rawValue,
                        trashedAt, createdAt, updatedAt, try cover.map(JSONColumn.encode), isFullWidth, isSmallText,
                        favorite?.rawValue, visitedAt, isTemplate, fieldClocks.databaseJSON]
        )
    }

    func update(in db: Database) throws {
        try db.cachedStatement(
            sql: """
                UPDATE page SET title = ?, icon = ?, parentId = ?, sortKey = ?, trashedAt = ?,
                    updatedAt = ?, cover = ?, isFullWidth = ?, isSmallText = ?, favorite = ?, visitedAt = ?, isTemplate = ?,
                    fieldClocks = ?
                WHERE id = ?
                """
        ).execute(arguments: [title, icon, parentId?.databaseText, sortKey.rawValue, trashedAt,
                        updatedAt, try cover.map(JSONColumn.encode), isFullWidth, isSmallText, favorite?.rawValue, visitedAt, isTemplate,
                        fieldClocks.databaseJSON, id.databaseText]
        )
    }
}

extension Block {
    init(row: Row) throws {
        guard let kind = BlockKind(rawValue: row["kind"]) else {
            throw NotesStoreError.corruptedRecord("Колонка kind — неизвестный тип блока")
        }
        let textBaseClock: String? = row["textBaseClock"]
        let color: String? = row["color"]
        self.init(
            id: try RowDecoding.uuid(row, "id"),
            pageId: try RowDecoding.uuid(row, "pageId"),
            kind: kind,
            text: InlineText(row["text"], runs: try RowDecoding.json([StyledRun].self, row, "textStyles")),
            indent: row["indent"],
            isChecked: row["isChecked"],
            linkedPageId: RowDecoding.optionalUUID(row, "linkedPageId"),
            sortKey: try RowDecoding.sortKey(row),
            containerId: RowDecoding.optionalUUID(row, "containerId"),
            color: try color.map { try JSONDecoder().decode(BlockColor.self, from: Data($0.utf8)) } ?? .none,
            props: try RowDecoding.json(BlockProps.self, row, "props"),
            fieldClocks: try RowDecoding.json(BlockFieldClocks.self, row, "fieldClocks"),
            textBaseClock: textBaseClock.flatMap(HybridTimestamp.init)
        )
    }

    func insert(into db: Database) throws {
        try db.cachedStatement(
            sql: """
                INSERT INTO block (id, pageId, kind, text, textStyles, indent, isChecked, linkedPageId,
                    sortKey, containerId, color, props, isDeleted, fieldClocks, textBaseClock)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """
        ).execute(arguments: [id.databaseText, pageId.databaseText, kind.rawValue, text.string,
                        try JSONColumn.encodeRuns(text.runs), indent, isChecked, linkedPageId?.databaseText,
                        sortKey.rawValue, containerId?.databaseText, try JSONColumn.encodeColor(color), try JSONColumn.encodeProps(props),
                        fieldClocks.databaseJSON, textBaseClock?.description]
        )
    }

    func update(in db: Database) throws {
        try db.cachedStatement(
            sql: """
                UPDATE block SET kind = ?, text = ?, textStyles = ?, indent = ?, isChecked = ?, linkedPageId = ?,
                    sortKey = ?, containerId = ?, color = ?, props = ?, fieldClocks = ?, textBaseClock = ?
                WHERE id = ?
                """
        ).execute(arguments: [kind.rawValue, text.string, try JSONColumn.encodeRuns(text.runs), indent, isChecked,
                        linkedPageId?.databaseText, sortKey.rawValue, containerId?.databaseText, try JSONColumn.encodeColor(color),
                        try JSONColumn.encodeProps(props), fieldClocks.databaseJSON, textBaseClock?.description, id.databaseText]
        )
    }
}

extension Conflict {
    init(row: Row) throws {
        self.init(
            id: try RowDecoding.uuid(row, "id"),
            blockId: try RowDecoding.uuid(row, "blockId"),
            localVersion: try RowDecoding.json(InlineText.self, row, "localVersion"),
            remoteVersion: try RowDecoding.json(InlineText.self, row, "remoteVersion"),
            remoteDeviceName: row["remoteDeviceName"],
            detectedAt: row["detectedAt"],
            resolvedAt: row["resolvedAt"]
        )
    }

    func insert(into db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO conflict (id, blockId, localVersion, remoteVersion, remoteDeviceName, detectedAt, resolvedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id.databaseText, blockId.databaseText, try JSONColumn.encode(localVersion),
                        try JSONColumn.encode(remoteVersion), remoteDeviceName, detectedAt, resolvedAt]
        )
    }

    func update(in db: Database) throws {
        try db.execute(
            sql: "UPDATE conflict SET localVersion = ?, remoteVersion = ?, remoteDeviceName = ?, resolvedAt = ? WHERE id = ?",
            arguments: [try JSONColumn.encode(localVersion), try JSONColumn.encode(remoteVersion), remoteDeviceName,
                        resolvedAt, id.databaseText]
        )
    }
}

extension WindowState {
    init(row: Row) throws {
        let collapsed = try RowDecoding.json([UUID].self, row, "collapsedPageIds")
        // Вкладки и свёрнутые разделы — вид этого Mac: испорченная или незнакомая запись читается как «нет».
        let tabs = (row["tabs"] as String?).flatMap { try? JSONDecoder().decode(TabsState.self, from: Data($0.utf8)) }
        let sections = (row["collapsedSidebarSections"] as String?)
            .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }?
            .compactMap(SidebarSectionID.init(rawValue:)) ?? []
        self.init(
            windowId: try RowDecoding.uuid(row, "windowId"),
            openPageId: RowDecoding.optionalUUID(row, "openPageId"),
            collapsedPageIds: Set(collapsed),
            sidebarWidth: row["sidebarWidth"],
            isSidebarCollapsed: row["isSidebarCollapsed"],
            tabs: tabs,
            collapsedSidebarSections: Set(sections)
        )
    }

    func save(in db: Database) throws {
        let collapsed = collapsedPageIds.map(\.databaseText).sorted()
        try db.execute(
            sql: """
                INSERT INTO window_state (windowId, openPageId, collapsedPageIds, sidebarWidth, isSidebarCollapsed, tabs,
                                          collapsedSidebarSections)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(windowId) DO UPDATE SET openPageId = excluded.openPageId,
                    collapsedPageIds = excluded.collapsedPageIds, sidebarWidth = excluded.sidebarWidth,
                    isSidebarCollapsed = excluded.isSidebarCollapsed, tabs = excluded.tabs,
                    collapsedSidebarSections = excluded.collapsedSidebarSections
                """,
            arguments: [windowId.databaseText, openPageId?.databaseText, try JSONColumn.encode(collapsed), sidebarWidth,
                        isSidebarCollapsed, try tabs.map(JSONColumn.encode),
                        try JSONColumn.encode(collapsedSidebarSections.map(\.rawValue).sorted())]
        )
    }
}

extension ReminderState {
    init?(row: Row) {
        guard let mentionId = RowDecoding.optionalUUID(row, "mentionId"), let clock = HybridTimestamp(row["doneClock"] as String) else { return nil }
        self.init(mentionId: mentionId, doneAt: row["doneAt"], doneClock: clock)
    }
}
