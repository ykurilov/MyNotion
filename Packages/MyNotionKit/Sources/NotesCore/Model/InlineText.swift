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

extension InlineText {
    /// Единая запись того же оформления: отрезки одного стиля слиты, выходы за край текста срезаны,
    /// у символа не больше одной ссылки (побеждает последняя), порядок — по началу, затем по стилю.
    /// Так одинаковый вид текста всегда хранится одинаково, и сравнение «изменилось ли» честное.
    public func normalized() -> InlineText {
        let length = (string as NSString).length
        guard length > 0, !runs.isEmpty else { return InlineText(string) }

        var flags = [[Bool]](repeating: [Bool](repeating: false, count: length), count: InlineStyle.flagStyles.count)
        var links = [URL?](repeating: nil, count: length)
        for run in runs {
            let start = max(run.start, 0)
            let end = min(run.start + run.length, length)
            guard start < end else { continue }
            for index in start..<end {
                switch run.style {
                case .link(let url): links[index] = url
                default: flags[run.style.rank][index] = true
                }
            }
        }

        var normalizedRuns: [StyledRun] = []
        for (rank, style) in InlineStyle.flagStyles.enumerated() {
            var index = 0
            while index < length {
                guard flags[rank][index] else { index += 1; continue }
                let start = index
                while index < length, flags[rank][index] { index += 1 }
                normalizedRuns.append(StyledRun(start: start, length: index - start, style: style))
            }
        }
        var index = 0
        while index < length {
            guard let url = links[index] else { index += 1; continue }
            let start = index
            while index < length, links[index] == url { index += 1 }
            normalizedRuns.append(StyledRun(start: start, length: index - start, style: .link(url)))
        }
        normalizedRuns.sort { ($0.start, $0.style.rank, $0.length) < ($1.start, $1.style.rank, $1.length) }
        return InlineText(string, runs: normalizedRuns)
    }
}

extension InlineStyle {
    /// Стили-признаки без значения, по порядку их места в записи.
    static let flagStyles: [InlineStyle] = [.bold, .italic, .strikethrough, .code]

    var rank: Int {
        switch self {
        case .bold: 0
        case .italic: 1
        case .strikethrough: 2
        case .code: 3
        case .link: 4
        }
    }
}
