import Foundation

/// `JSONValue` 002 (свойства блоков) — и значения баз (data-model.md: `config`, `value`, `filter`, `layoutOptions`):
/// неизвестные ключи от более новой версии сохраняются и уходят дальше без потерь.
extension JSONValue {
    public static let emptyObject = JSONValue.object([:])

    public subscript(key: String) -> JSONValue? {
        get { if case .object(let object) = self { object[key] } else { nil } }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }

    /// Текст JSON: ключи по алфавиту, без экранирования «/» — одинаковый на всех Mac.
    public var jsonText: String { FastJSON.text(self) }

    /// Разбор текста JSON; испорченный текст — `nil`.
    public init?(jsonText: String) {
        guard let value = FastJSON.parse(jsonText) ?? (try? JSONDecoder().decode(JSONValue.self, from: Data(jsonText.utf8))) else { return nil }
        self = value
    }

    /// Значение из `Codable` (настройки типа, дерево фильтра).
    public init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    /// Обратно в `Codable`.
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
}
