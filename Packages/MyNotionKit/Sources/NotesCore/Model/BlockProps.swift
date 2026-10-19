import Foundation

/// Свойства блока по его типу (data-model.md, «props по типам»): объект JSON. Неизвестные ключи хранятся как есть —
/// более новая версия MyNotion может добавить своё, и эта их не потеряет.
public struct BlockProps: Sendable, Hashable, Codable {
    public var values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public static let empty = BlockProps()

    public var isEmpty: Bool { values.isEmpty }

    /// Свойства нового блока.
    public static func defaults(for kind: BlockKind) -> BlockProps {
        var props = BlockProps()
        switch kind {
        case .callout: props.icon = "💡"
        case .code: props.language = "plain"
        case .table:
            props.hasHeaderRow = false
            props.hasHeaderColumn = false
        case .tableColumn: props.width = 120
        default: break
        }
        return props
    }

    public init(from decoder: any Decoder) throws {
        values = try decoder.singleValueContainer().decode([String: JSONValue].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    // MARK: Поля по типам

    /// Выноска: эмодзи иконки.
    public var icon: String? {
        get { values["icon"]?.string }
        set { values["icon"] = newValue.map(JSONValue.string) }
    }

    /// Закладка: значок сайта — тот же ключ `icon`, но файлом.
    public var iconAttachment: AttachmentRef? {
        get { decoded("icon") }
        set { encode(newValue, as: "icon") }
    }

    /// Код: id языка (`swift`, `python`, … `plain`).
    public var language: String? {
        get { values["language"]?.string }
        set { values["language"] = newValue.map(JSONValue.string) }
    }

    /// Картинка, файл, видео-файл.
    public var attachment: AttachmentRef? {
        get { decoded("attachment") }
        set { encode(newValue, as: "attachment") }
    }

    /// Картинка и видео — доля колонки 0,1…1; столбец таблицы — ширина в точках.
    public var width: Double? {
        get { values["width"]?.number }
        set { values["width"] = newValue.map(JSONValue.number) }
    }

    /// Картинка: размер в пикселях `[ширина, высота]`.
    public var pixelSize: PixelSize? {
        get {
            guard case .array(let items)? = values["pixelSize"], items.count == 2,
                  let width = items[0].number, let height = items[1].number else { return nil }
            return PixelSize(width: Int(width), height: Int(height))
        }
        set { values["pixelSize"] = newValue.map { .array([.number(Double($0.width)), .number(Double($0.height))]) } }
    }

    /// Видео: откуда.
    public var videoSource: VideoSource? {
        get { values["source"]?.string.flatMap(VideoSource.init(rawValue:)) }
        set { values["source"] = newValue.map { .string($0.rawValue) } }
    }

    /// Видео YouTube и Vimeo, закладка: адрес.
    public var url: URL? {
        get { values["url"]?.string.flatMap(URL.init(string:)) }
        set { values["url"] = newValue.map { .string($0.absoluteString) } }
    }

    /// Видео: обложка.
    public var poster: AttachmentRef? {
        get { decoded("poster") }
        set { encode(newValue, as: "poster") }
    }

    public var title: String? {
        get { values["title"]?.string }
        set { values["title"] = newValue.map(JSONValue.string) }
    }

    /// Закладка: описание сайта.
    public var description: String? {
        get { values["description"]?.string }
        set { values["description"] = newValue.map(JSONValue.string) }
    }

    /// Закладка: картинка сайта.
    public var image: AttachmentRef? {
        get { decoded("image") }
        set { encode(newValue, as: "image") }
    }

    /// Закладка: когда данные карточки получены.
    public var fetchedAt: Date? {
        get { values["fetchedAt"]?.string.flatMap { try? Date($0, strategy: .iso8601) } }
        set { values["fetchedAt"] = newValue.map { .string($0.formatted(.iso8601)) } }
    }

    /// Таблица: первая строка — заголовок.
    public var hasHeaderRow: Bool? {
        get { values["hasHeaderRow"]?.bool }
        set { values["hasHeaderRow"] = newValue.map(JSONValue.bool) }
    }

    /// Таблица: первый столбец — заголовок.
    public var hasHeaderColumn: Bool? {
        get { values["hasHeaderColumn"]?.bool }
        set { values["hasHeaderColumn"] = newValue.map(JSONValue.bool) }
    }

    /// Ячейка: id её столбца.
    public var columnId: UUID? {
        get { values["columnId"]?.string.flatMap(UUID.init(uuidString:)) }
        set { values["columnId"] = newValue.map { .string($0.uuidString.lowercased()) } }
    }

    /// Колонка: доля ширины 0,1…0,9.
    public var widthRatio: Double? {
        get { values["widthRatio"]?.number }
        set { values["widthRatio"] = newValue.map(JSONValue.number) }
    }

    private func decoded<T: Decodable>(_ key: String) -> T? {
        guard let value = values[key], let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private mutating func encode(_ value: (some Encodable)?, as key: String) {
        guard let value else {
            values[key] = nil
            return
        }
        values[key] = (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
}

public struct PixelSize: Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum VideoSource: String, Sendable, Hashable, Codable {
    case file
    case youtube
    case vimeo
}

/// Значение JSON как есть: для свойств, которых эта версия не знает.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Целые — без «.0»: так их пишет и читает любая версия.
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    public var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }
}
