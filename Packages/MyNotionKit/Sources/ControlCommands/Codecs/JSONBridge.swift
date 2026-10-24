import ControlProtocol
import Foundation
import NotesCore

/// `JSONValue` ядра ↔ `ControlJSON` протокола: одно и то же JSON, разные модули (протокол не зависит от ядра).
extension JSONValue {
    public var control: ControlJSON {
        switch self {
        case .null: .null
        case .bool(let value): .bool(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .array(let items): .array(items.map(\.control))
        case .object(let object): .object(object.mapValues(\.control))
        }
    }
}

extension ControlJSON {
    public var core: JSONValue {
        switch self {
        case .null: .null
        case .bool(let value): .bool(value)
        case .number(let value): .number(value)
        case .string(let value): .string(value)
        case .array(let items): .array(items.map(\.core))
        case .object(let object): .object(object.mapValues(\.core))
        }
    }
}

extension UUID {
    /// Id в ответах команд — строчными буквами.
    public var controlText: String { uuidString.lowercased() }
}

extension Date {
    /// ISO 8601 с поясом (UTC, `Z`).
    public var controlText: String { formatted(.iso8601) }
}

/// Названия и иконки страниц для упоминаний; `nil` — страницы нет.
public typealias MentionTitles = @Sendable (UUID) -> (title: String, icon: String?)?
/// Вложение по id — для обложек, файлов и картинок на входе команд.
public typealias AttachmentLookup = @Sendable (UUID) -> AttachmentRef?
