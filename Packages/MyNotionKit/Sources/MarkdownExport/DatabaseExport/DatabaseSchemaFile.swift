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
