import Foundation
import NotesCore

/// Цвет блока из строки `<!-- mynotion:color text=".." background=".." -->` нашей выгрузки (contracts/markdown-and-notion.md).
/// Нет атрибута — цвет нового блока этого вида; `default` — без цвета.
struct NotionColorComment: Equatable {
    private enum Value: Equatable {
        case inherited
        case none
        case color(NotionColor)
    }

    private var text = Value.inherited
    private var background = Value.inherited

    /// `nil` — это не наш комментарий о цвете.
    static func parse(_ line: String) -> NotionColorComment? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") else { return nil }
        let body = trimmed.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        guard body == "mynotion:color" || body.hasPrefix("mynotion:color ") else { return nil }
        var comment = NotionColorComment()
        comment.text = value(of: "text", in: body)
        comment.background = value(of: "background", in: body)
        return comment
    }

    /// Цвет блока этого вида.
    func resolved(for kind: BlockKind) -> BlockColor {
        let defaults = BlockColor.defaults(for: kind)
        return BlockColor(text: Self.resolve(text, default: defaults.text), background: Self.resolve(background, default: defaults.background))
    }

    private static func resolve(_ value: Value, default fallback: NotionColor?) -> NotionColor? {
        switch value {
        case .inherited: fallback
        case .none: nil
        case .color(let color): color
        }
    }

    /// Неизвестное имя цвета — как будто атрибута нет.
    private static func value(of name: String, in body: String) -> Value {
        guard let match = body.range(of: "(?:^|\\s)\(name)=\"([a-z]+)\"", options: .regularExpression) else { return .inherited }
        let raw = body[match].split(separator: "\"").dropFirst().first.map(String.init) ?? ""
        if raw == "default" { return .none }
        return NotionColor(rawValue: raw).map(Value.color) ?? .inherited
    }
}
