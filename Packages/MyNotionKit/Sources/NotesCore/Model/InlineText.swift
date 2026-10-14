import Foundation

/// Текст блока с оформлением в строке: строка и отрезки `{start, length, style}`.
/// Смещения — в единицах UTF-16, как у `NSString` и TextKit.
/// Для синхронизации это одно поле: текст и оформление меняются вместе.
public struct InlineText: Sendable, Hashable, Codable {
    public var string: String
    public var runs: [StyledRun]

    public init(_ string: String = "", runs: [StyledRun] = []) {
        self.string = string
        self.runs = runs
    }

    public static let empty = InlineText()
}

public struct StyledRun: Sendable, Hashable, Codable {
    public var start: Int
    public var length: Int
    public var style: InlineStyle

    public init(start: Int, length: Int, style: InlineStyle) {
        self.start = start
        self.length = length
        self.style = style
    }

    private enum CodingKeys: String, CodingKey { case start, length, style, url }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Int.self, forKey: .start)
        length = try container.decode(Int.self, forKey: .length)
        switch try container.decode(String.self, forKey: .style) {
        case "bold": style = .bold
        case "italic": style = .italic
        case "strikethrough": style = .strikethrough
        case "code": style = .code
        case "link": style = .link(try container.decode(URL.self, forKey: .url))
        case let unknown:
            throw DecodingError.dataCorruptedError(forKey: .style, in: container, debugDescription: "Неизвестное оформление: \(unknown)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(length, forKey: .length)
        switch style {
        case .bold: try container.encode("bold", forKey: .style)
        case .italic: try container.encode("italic", forKey: .style)
        case .strikethrough: try container.encode("strikethrough", forKey: .style)
        case .code: try container.encode("code", forKey: .style)
        case .link(let url):
            try container.encode("link", forKey: .style)
            try container.encode(url, forKey: .url)
        }
    }
}

public enum InlineStyle: Sendable, Hashable {
    case bold
    case italic
    case strikethrough
    case code
    case link(URL)
}
