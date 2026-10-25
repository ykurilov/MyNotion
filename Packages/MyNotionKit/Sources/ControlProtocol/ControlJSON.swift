import Foundation

/// Значение JSON аргументов и ответов команд. Своё, а не `JSONValue` ядра: протокол не зависит от модулей приложения,
/// его видит и консольная команда.
public enum ControlJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ControlJSON])
    case object([String: ControlJSON])

    public var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    /// Целое число без дробной части.
    public var int: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }

    public var bool: Bool? {
        if case .bool(let value) = self { value } else { nil }
    }

    public var array: [ControlJSON]? {
        if case .array(let value) = self { value } else { nil }
    }

    public var object: [String: ControlJSON]? {
        if case .object(let value) = self { value } else { nil }
    }

    public var isNull: Bool { self == .null }

    public subscript(key: String) -> ControlJSON? {
        object?[key]
    }

    public subscript(index: Int) -> ControlJSON? {
        guard let array, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Значение по пути `a.b.0.c` (ссылки пакета `$N.путь`).
    public func value(atPath path: String) -> ControlJSON? {
        var current: ControlJSON? = self
        for part in path.split(separator: ".", omittingEmptySubsequences: true) {
            guard let value = current else { return nil }
            if let index = Int(part), case .array = value {
                current = value[index]
            } else {
                current = value[String(part)]
            }
        }
        return current
    }

    /// Строка JSON без переносов, ключи по алфавиту: одинаковые значения дают одинаковые байты.
    public func encodedText() -> String {
        String(decoding: (try? ControlCoding.encoder.encode(self)) ?? Data("null".utf8), as: UTF8.self)
    }

    /// Разобрать текст JSON (аргумент `--props`, `--values`, файл пакета).
    public init(parsing text: String) throws {
        self = try ControlCoding.decoder.decode(ControlJSON.self, from: Data(text.utf8))
    }
}

extension ControlJSON: Codable {
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
        } else if let value = try? container.decode([ControlJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ControlJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Целые — без «.0».
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension ControlJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: ControlJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, ControlJSON)...) {
        self = .object(Dictionary(elements) { _, last in last })
    }
    public init(nilLiteral: ()) { self = .null }
}

extension ControlJSON {
    public init(_ value: String?) { self = value.map(ControlJSON.string) ?? .null }
    public init(_ value: Int) { self = .number(Double(value)) }
    public init(_ value: UUID?) { self = value.map { .string($0.uuidString.lowercased()) } ?? .null }
    public init(_ value: Date?) { self = value.map { .string(ControlCoding.dateText($0)) } ?? .null }
}

/// Общие кодировщики протокола: строка без переносов, ключи по алфавиту, `/` без экранирования.
public enum ControlCoding {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder { JSONDecoder() }

    /// ISO 8601 с поясом (contracts/block-json.md).
    public static func dateText(_ date: Date) -> String {
        var style = Date.ISO8601FormatStyle()
        style.timeZone = .current
        return date.formatted(style)
    }
}
