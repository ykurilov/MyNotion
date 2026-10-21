import Foundation
import NotesCore
import UniformTypeIdentifiers

/// Значение ячейки «Файлы и медиа» по частям (data-model.md: `[{attachment: AttachmentRef} | {url, name}]`).
/// Запись непонятного вида (от новой версии) сохраняется как есть.
public enum FilesValue {
    public enum Item: Sendable, Hashable {
        case file(AttachmentRef)
        case link(url: String, name: String)
        case other(JSONValue)

        public var name: String {
            switch self {
            case .file(let ref): ref.name
            case .link(_, let name): name
            case .other(let value): value["name"]?.string ?? ""
            }
        }

        var json: JSONValue {
            switch self {
            case .file(let ref): ["attachment": (try? JSONValue(encoding: ref)) ?? .null]
            case .link(let url, let name): ["url": .string(url), "name": .string(name)]
            case .other(let value): value
            }
        }
    }

    public static func items(_ value: JSONValue?) -> [Item] {
        (value?.array ?? []).map { item in
            if let ref = item["attachment"].flatMap({ try? $0.decoded(as: AttachmentRef.self) }) { return .file(ref) }
            if let url = item["url"]?.string { return .link(url: url, name: item["name"]?.string ?? url) }
            return .other(item)
        }
    }

    /// Пустой список — пустая ячейка.
    public static func json(_ items: [Item]) -> JSONValue? {
        items.isEmpty ? nil : .array(items.map(\.json))
    }

    /// «Ссылка» окна файлов: без схемы — `https://`; имя — последняя часть пути или адрес. Не ссылка — `nil`.
    public static func link(_ text: String) -> Item? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), let host = url.host(), host.contains(".") else { return nil }
        let last = url.lastPathComponent
        return .link(url: full, name: last.isEmpty || last == "/" ? host : last)
    }

    /// Картинка — показывается уменьшенной копией (только свой файл, не ссылка).
    public static func isImage(_ item: Item) -> Bool {
        guard case .file(let ref) = item else { return false }
        return UTType(ref.contentType)?.conforms(to: .image) == true
    }
}
