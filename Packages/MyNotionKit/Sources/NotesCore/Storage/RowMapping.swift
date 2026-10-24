import Foundation
import GRDB

// Перевод записей в строки таблиц и обратно. id хранятся строками UUID в нижнем регистре,
// метки часов — строками HybridTimestamp, наборы меток и оформление — JSON.

extension UUID {
    package var databaseText: String { uuidString.lowercased() }
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

/// Места колонок блока в строках одной выборки: имя колонки ищется один раз на выборку, а не по 15 раз на блок
/// (профиль переключения вкладок, 003: поиск колонок по имени — четверть разбора блоков страницы).
struct BlockColumns {
    let id, pageId, kind, text, textStyles, indent, isChecked, linkedPageId, sortKey, containerId, color, props, fieldClocks,
        textBaseClock: Int

    init(_ row: Row) throws {
        let names = Array(row.columnNames)
        func index(_ name: String) throws -> Int {
            guard let index = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw NotesStoreError.corruptedRecord("Нет колонки \(name)")
            }
            return index
        }
        id = try index("id")
        pageId = try index("pageId")
        kind = try index("kind")
        text = try index("text")
        textStyles = try index("textStyles")
        indent = try index("indent")
        isChecked = try index("isChecked")
        linkedPageId = try index("linkedPageId")
        sortKey = try index("sortKey")
        containerId = try index("containerId")
        color = try index("color")
        props = try index("props")
        fieldClocks = try index("fieldClocks")
        textBaseClock = try index("textBaseClock")
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
    /// Прочитать набор меток `{"поле":"метка",…}`, как его пишет `encodeClocks`, проходом по байтам: открытие страницы
    /// на 1 000 блоков разбирает 1 000 таких наборов (research R15). Каждое поле — в `assign` по имени. `false` — запись
    /// не в этом виде (пробелы, экранирование, не метка): её читает JSONDecoder.
    static func decodeClocks(_ text: String, _ assign: (_ field: Slice<UnsafeBufferPointer<UInt8>>, HybridTimestamp) -> Void) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            let quote = UInt8(ascii: "\""), end = bytes.count
            guard end >= 2, bytes[0] == UInt8(ascii: "{"), bytes[end - 1] == UInt8(ascii: "}") else { return false }
            var position = 1
            if position == end - 1 { return true }
            while true {
                guard bytes[position] == quote else { return false }
                let keyStart = position + 1
                var keyEnd = keyStart
                while keyEnd < end, bytes[keyEnd] != quote, bytes[keyEnd] != UInt8(ascii: "\\") { keyEnd += 1 }
                let stampStart = keyEnd + 3
                guard keyEnd < end, bytes[keyEnd] == quote, stampStart + HybridTimestamp.textLength < end,
                      bytes[keyEnd + 1] == UInt8(ascii: ":"), bytes[keyEnd + 2] == quote,
                      bytes[stampStart + HybridTimestamp.textLength] == quote,
                      let stamp = HybridTimestamp.parse(bytes[stampStart..<stampStart + HybridTimestamp.textLength]) else { return false }
                assign(bytes[keyStart..<keyEnd], stamp)
                position = stampStart + HybridTimestamp.textLength + 1
                if bytes[position] == UInt8(ascii: "}") { return position == end - 1 }
                guard bytes[position] == UInt8(ascii: ",") else { return false }
                position += 1
            }
        }
    }

    /// Имя поля из записи совпадает с `name`.
    static func field(_ bytes: Slice<UnsafeBufferPointer<UInt8>>, is name: StaticString) -> Bool {
        guard bytes.count == name.utf8CodeUnitCount else { return false }
        return name.withUTF8Buffer { expected in zip(bytes, expected).allSatisfy { $0 == $1 } }
    }

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

extension PageFieldClocks {
    init(databaseJSON text: String) throws {
        var clocks = PageFieldClocks()
        let isPlain = JSONColumn.decodeClocks(text) { field, stamp in
            for (name, path) in Self.databaseFields where JSONColumn.field(field, is: name) {
                clocks[keyPath: path] = stamp
                return
            }
        }
        self = isPlain ? clocks : try JSONDecoder().decode(PageFieldClocks.self, from: Data(text.utf8))
    }

    nonisolated(unsafe) private static let databaseFields: [(StaticString, WritableKeyPath<PageFieldClocks, HybridTimestamp?>)] = [
        ("title", \.title), ("icon", \.icon), ("placement", \.placement), ("trashedAt", \.trashedAt), ("cover", \.cover),
        ("isFullWidth", \.isFullWidth), ("isSmallText", \.isSmallText), ("favorite", \.favorite), ("visitedAt", \.visitedAt),
        ("isTemplate", \.isTemplate),
    ]
}

extension BlockFieldClocks {
    init(databaseJSON text: String) throws {
        var clocks = BlockFieldClocks()
        let isPlain = JSONColumn.decodeClocks(text) { field, stamp in
            for (name, path) in Self.databaseFields where JSONColumn.field(field, is: name) {
                clocks[keyPath: path] = stamp
                return
            }
        }
        self = isPlain ? clocks : try JSONDecoder().decode(BlockFieldClocks.self, from: Data(text.utf8))
    }

    nonisolated(unsafe) private static let databaseFields: [(StaticString, WritableKeyPath<BlockFieldClocks, HybridTimestamp?>)] = [
        ("kindAndIndent", \.kindAndIndent), ("text", \.text), ("isChecked", \.isChecked), ("placement", \.placement),
        ("color", \.color), ("props", \.props), ("deleted", \.deleted),
    ]

    var databaseJSON: String {
        JSONColumn.encodeClocks([("kindAndIndent", kindAndIndent), ("text", text), ("isChecked", isChecked),
                                 ("placement", placement), ("color", color), ("props", props), ("deleted", deleted)])
    }
}

extension Page {
    package init(row: Row) throws {
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
            fieldClocks: try PageFieldClocks(databaseJSON: row["fieldClocks"])
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
        try self.init(row: row, columns: BlockColumns(row))
    }

    init(row: Row, columns c: BlockColumns) throws {
        guard let kind = BlockKind(rawValue: row[c.kind]) else {
            throw NotesStoreError.corruptedRecord("Колонка kind — неизвестный тип блока")
        }
        let textBaseClock: String? = row[c.textBaseClock]
        let color: String? = row[c.color]
        guard let id = (row[c.id] as String?).flatMap(UUID.init(uuidString:)) else { throw NotesStoreError.corruptedRecord("Колонка id — не UUID") }
        guard let pageId = (row[c.pageId] as String?).flatMap(UUID.init(uuidString:)) else {
            throw NotesStoreError.corruptedRecord("Колонка pageId — не UUID")
        }
        guard let sortKey = FractionalSortKey(rawValue: row[c.sortKey]) else {
            throw NotesStoreError.corruptedRecord("Колонка sortKey — не ключ порядка")
        }
        let textStyles: String = row[c.textStyles]
        let props: String = row[c.props]
        self.init(
            id: id,
            pageId: pageId,
            kind: kind,
            text: InlineText(row[c.text], runs: textStyles == "[]" ? [] : try JSONDecoder().decode([StyledRun].self, from: Data(textStyles.utf8))),
            indent: row[c.indent],
            isChecked: row[c.isChecked],
            linkedPageId: (row[c.linkedPageId] as String?).flatMap(UUID.init(uuidString:)),
            sortKey: sortKey,
            containerId: (row[c.containerId] as String?).flatMap(UUID.init(uuidString:)),
            color: try color.map { try JSONDecoder().decode(BlockColor.self, from: Data($0.utf8)) } ?? .none,
            props: props == "{}" ? .empty : try JSONDecoder().decode(BlockProps.self, from: Data(props.utf8)),
            fieldClocks: try BlockFieldClocks(databaseJSON: row[c.fieldClocks]),
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
