import Foundation

/// Цвет Notion (research R13): девять цветов; «по умолчанию» — отсутствие цвета (`nil`).
/// Значения для экрана в светлой и тёмной теме — в `VisualStyle/Palette`.
public enum NotionColor: String, Sendable, Hashable, CaseIterable, Codable {
    case gray
    case brown
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink
    case red
}

/// Цвет всего блока (FR-112): текста и подложки.
public struct BlockColor: Sendable, Hashable, Codable {
    public var text: NotionColor?
    public var background: NotionColor?

    public init(text: NotionColor? = nil, background: NotionColor? = nil) {
        self.text = text
        self.background = background
    }

    public static let none = BlockColor()

    public var isNone: Bool { text == nil && background == nil }

    /// Цвет нового блока: у выноски — серая подложка.
    public static func defaults(for kind: BlockKind) -> BlockColor {
        kind == .callout ? BlockColor(background: .gray) : .none
    }

    private enum CodingKeys: String, CodingKey { case text, background }

    /// `{text: цвет|null, background: цвет|null}` — оба ключа всегда на месте (contracts/sync-and-files-api.md).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(background, forKey: .background)
    }
}
