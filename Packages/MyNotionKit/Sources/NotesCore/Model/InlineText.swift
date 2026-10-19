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

    private enum CodingKeys: String, CodingKey { case start, length, style, url, color, pageId, date, latex }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Int.self, forKey: .start)
        length = try container.decode(Int.self, forKey: .length)
        switch try container.decode(String.self, forKey: .style) {
        case "bold": style = .bold
        case "italic": style = .italic
        case "strikethrough": style = .strikethrough
        case "code": style = .code
        case "underline": style = .underline
        case "link": style = .link(try container.decode(URL.self, forKey: .url))
        case "textColor": style = .textColor(try container.decode(NotionColor.self, forKey: .color))
        case "backgroundColor": style = .backgroundColor(try container.decode(NotionColor.self, forKey: .color))
        case "mention": style = .mention(try container.decode(UUID.self, forKey: .pageId))
        case "date": style = .date(try container.decode(DateMention.self, forKey: .date))
        case "equation": style = .equation(try container.decode(String.self, forKey: .latex))
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
        case .underline: try container.encode("underline", forKey: .style)
        case .link(let url):
            try container.encode("link", forKey: .style)
            try container.encode(url, forKey: .url)
        case .textColor(let color):
            try container.encode("textColor", forKey: .style)
            try container.encode(color, forKey: .color)
        case .backgroundColor(let color):
            try container.encode("backgroundColor", forKey: .style)
            try container.encode(color, forKey: .color)
        case .mention(let pageId):
            try container.encode("mention", forKey: .style)
            try container.encode(pageId, forKey: .pageId)
        case .date(let date):
            try container.encode("date", forKey: .style)
            try container.encode(date, forKey: .date)
        case .equation(let latex):
            try container.encode("equation", forKey: .style)
            try container.encode(latex, forKey: .latex)
        }
    }
}

public enum InlineStyle: Sendable, Hashable {
    case bold
    case italic
    case strikethrough
    case code
    case underline
    case link(URL)
    /// Цвет текста — один на символ, как ссылка (002, research R13).
    case textColor(NotionColor)
    /// Цвет фона — один на символ.
    case backgroundColor(NotionColor)
    /// Упоминание страницы — атом: ровно на одном знаке U+FFFC (research R12).
    case mention(UUID)
    /// Дата или напоминание — атом.
    case date(DateMention)
    /// Формула в строке — атом, запись LaTeX (research R6).
    case equation(String)

    /// Атом стоит ровно на одном знаке U+FFFC.
    public var isAtom: Bool {
        switch self {
        case .mention, .date, .equation: true
        default: false
        }
    }
}

extension InlineText {
    /// Знак-вложение: на нём живёт атом — упоминание, дата, формула.
    public static let objectReplacementCharacter: unichar = 0xFFFC

    /// Единая запись того же оформления: отрезки одного стиля слиты, выходы за край текста срезаны,
    /// у символа не больше одной ссылки, одного цвета текста и одного цвета фона (побеждает последний),
    /// порядок — по началу, затем по стилю. Атом стоит ровно на одном U+FFFC: атом без своего знака отбрасывается,
    /// знак без атома — тоже, вместе с местом в тексте. Так одинаковый вид текста всегда хранится одинаково,
    /// и сравнение «изменилось ли» честное.
    public func normalized() -> InlineText {
        let units = Array(string.utf16)
        let length = units.count
        guard length > 0 else { return InlineText(string) }
        let hasObjectCharacters = units.contains(Self.objectReplacementCharacter)
        guard !runs.isEmpty || hasObjectCharacters else { return InlineText(string) }

        var flags = [[Bool]](repeating: [Bool](repeating: false, count: length), count: InlineStyle.flagStyles.count)
        var links = [URL?](repeating: nil, count: length)
        var textColors = [NotionColor?](repeating: nil, count: length)
        var backgroundColors = [NotionColor?](repeating: nil, count: length)
        var atoms = [InlineStyle?](repeating: nil, count: length)
        for run in runs {
            let start = max(run.start, 0)
            let end = min(run.start + run.length, length)
            guard start < end else { continue }
            for index in start..<end {
                switch run.style {
                case .link(let url): links[index] = url
                case .textColor(let color): textColors[index] = color
                case .backgroundColor(let color): backgroundColors[index] = color
                case .mention, .date, .equation:
                    if units[index] == Self.objectReplacementCharacter { atoms[index] = run.style }
                default: flags[run.style.rank][index] = true
                }
            }
        }

        // Знаки U+FFFC без атома выпадают; `kept` — места, которые остаются, по порядку.
        var kept: [Int] = []
        kept.reserveCapacity(length)
        for index in 0..<length where units[index] != Self.objectReplacementCharacter || atoms[index] != nil {
            kept.append(index)
        }
        let normalizedString = kept.count == length ? string : String(decoding: kept.map { units[$0] }, as: UTF16.self)

        var normalizedRuns: [StyledRun] = []
        func collect<Value: Equatable>(_ values: [Value?], style: (Value) -> InlineStyle) {
            var position = 0
            while position < kept.count {
                guard let value = values[kept[position]] else { position += 1; continue }
                let start = position
                while position < kept.count, values[kept[position]] == value { position += 1 }
                normalizedRuns.append(StyledRun(start: start, length: position - start, style: style(value)))
            }
        }
        for (rank, style) in InlineStyle.flagStyles.enumerated() {
            collect(flags[rank].map { $0 ? true : nil }) { _ in style }
        }
        collect(links) { .link($0) }
        collect(textColors) { .textColor($0) }
        collect(backgroundColors) { .backgroundColor($0) }
        for (position, index) in kept.enumerated() {
            if let atom = atoms[index] { normalizedRuns.append(StyledRun(start: position, length: 1, style: atom)) }
        }
        normalizedRuns.sort { ($0.start, $0.style.rank, $0.length) < ($1.start, $1.style.rank, $1.length) }
        return InlineText(normalizedString, runs: normalizedRuns)
    }
}

extension InlineStyle {
    /// Стили-признаки без значения, по порядку их места в записи.
    static let flagStyles: [InlineStyle] = [.bold, .italic, .strikethrough, .code, .underline]

    var rank: Int {
        switch self {
        case .bold: 0
        case .italic: 1
        case .strikethrough: 2
        case .code: 3
        case .underline: 4
        case .link: 5
        case .textColor: 6
        case .backgroundColor: 7
        case .mention: 8
        case .date: 9
        case .equation: 10
        }
    }
}
