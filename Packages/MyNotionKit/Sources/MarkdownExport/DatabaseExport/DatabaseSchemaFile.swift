import Foundation
import NotesCore

/// Схема базы своей выгрузки — `Задачи.mynotion-database.json` рядом с `Задачи.csv` (contracts/sync-v4-and-export.md):
/// по ней импорт MyNotion возвращает базу целиком — типы, варианты с цветами, формулы, связи, виды, шаблоны и значения
/// как есть. Id — прежние: импорт заменяет их новыми и по ним же связывает строки, свойства и базы одной выгрузки.
public struct DatabaseSchemaFile: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1
    public static let fileSuffix = ".mynotion-database.json"

    public var formatVersion: Int
    public var databaseId: String
    public var title: String
    public var isInline: Bool
    public var defaultTemplateId: String?
    /// Все свойства, в том числе в «Удалённых свойствах» (`deletedAt`): их значения тоже не теряются.
    public var properties: [Property]
    public var options: [Option]
    public var views: [View]
    public var rows: [Row]
    /// Шаблоны строк — страницы в папке `Задачи/Шаблоны/`.
    public var templates: [Row]
    public var rowOrders: [RowOrderEntry]

    public struct Property: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var type: String
        public var config: JSONValue
        public var sortKey: String
        public var deletedAt: Date?
        /// У связи: CSV базы-цели от папки этого файла (для человека; импорт связывает по `targetDatabaseId`).
        public var relationTarget: String?
    }

    public struct Option: Codable, Sendable, Equatable {
        public var id: String
        public var propertyId: String
        public var name: String
        public var color: String
        public var sortKey: String
        public var statusGroup: String?
        public var deletedAt: Date?
    }

    public struct View: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var type: String
        public var sortKey: String
        public var filter: JSONValue?
        public var sorts: JSONValue
        public var columns: JSONValue
        public var group: JSONValue?
        public var layoutOptions: JSONValue
    }

    public struct Row: Codable, Sendable, Equatable {
        public var id: String
        /// Файл строки от папки этого файла: `Задачи/Позвонить в банк.md`.
        public var file: String
        public var title: String
        public var sortKey: String
        public var createdAt: Date
        public var updatedAt: Date
        /// Значения ячеек по id свойства, как в `db_cell` (пустые записи — `null`).
        public var cells: [String: JSONValue]
        /// Связи по id свойства: id строк-целей по порядку (у пары — с обеих сторон).
        public var relations: [String: [String]]
    }

    public struct RowOrderEntry: Codable, Sendable, Equatable {
        public var viewId: String
        public var rowId: String
        public var sortKey: String
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Даты — числом как есть: «Создано» и «Изменено» возвращаются до доли секунды.
        encoder.dateEncodingStrategy = .deferredToDate
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> DatabaseSchemaFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try decoder.decode(DatabaseSchemaFile.self, from: data)
    }
}

extension DatabaseSchemaFile {
    /// Схема из снимка базы. `rowFile` — файл строки или шаблона от папки схемы; `relationTarget` — CSV базы-цели связи.
    init(_ snapshot: DatabaseExportSnapshot, rowFile: (Page) -> String, relationTarget: (UUID) -> String?) {
        func row(_ page: Page) -> Row {
            var cells: [String: JSONValue] = [:]
            for (propertyId, value) in snapshot.cells[page.id] ?? [:] { cells[propertyId.databaseText] = value ?? .null }
            var relations: [String: [String]] = [:]
            for (propertyId, targets) in snapshot.relations[page.id] ?? [:] { relations[propertyId.databaseText] = targets.map(\.databaseText) }
            return Row(id: page.id.databaseText, file: rowFile(page), title: page.title, sortKey: page.sortKey.rawValue,
                       createdAt: page.createdAt, updatedAt: page.updatedAt, cells: cells, relations: relations)
        }
        self.init(
            formatVersion: Self.currentFormatVersion, databaseId: snapshot.schema.pageId.databaseText, title: snapshot.title,
            isInline: snapshot.schema.isInline, defaultTemplateId: snapshot.schema.defaultTemplateId?.databaseText,
            properties: snapshot.properties.map { property in
                Property(id: property.id.databaseText, name: property.name, type: property.kind.rawValue, config: property.config,
                         sortKey: property.sortKey.rawValue, deletedAt: property.deletedAt,
                         relationTarget: property.kind == .relation
                            ? property.config["targetDatabaseId"]?.string.flatMap(UUID.init(uuidString:)).flatMap(relationTarget) : nil)
            },
            options: snapshot.options.map { option in
                Option(id: option.id.databaseText, propertyId: option.propertyId.databaseText, name: option.name, color: option.color,
                       sortKey: option.sortKey.rawValue, statusGroup: option.statusGroup?.rawValue, deletedAt: option.deletedAt)
            },
            views: snapshot.views.map { view in
                View(id: view.id.databaseText, name: view.name, type: view.type, sortKey: view.sortKey.rawValue, filter: view.filter,
                     sorts: view.sorts, columns: view.columns, group: view.group, layoutOptions: view.layoutOptions)
            },
            rows: snapshot.rows.map(row), templates: snapshot.templates.map(row),
            rowOrders: snapshot.rowOrders.map { RowOrderEntry(viewId: $0.viewId.databaseText, rowId: $0.rowId.databaseText, sortKey: $0.sortKey.rawValue) })
    }
}
