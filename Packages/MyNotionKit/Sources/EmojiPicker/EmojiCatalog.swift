import Foundation

/// Разделы окна эмодзи по порядку, как у Notion: «Недавние» и группы Unicode `emoji-test.txt`.
public enum EmojiSection: String, CaseIterable, Sendable {
    case recent, people, nature, food, activities, travel, objects, symbols, flags

    public var title: String {
        switch self {
        case .recent: "Недавние"
        case .people: "Смайлы и люди"
        case .nature: "Животные и природа"
        case .food: "Еда"
        case .activities: "Занятия"
        case .travel: "Путешествия"
        case .objects: "Предметы"
        case .symbols: "Символы"
        case .flags: "Флаги"
        }
    }

    /// Системный значок раздела в нижней строке окна (как значки разделов у Notion).
    public var symbolName: String {
        switch self {
        case .recent: "clock"
        case .people: "face.smiling"
        case .nature: "leaf"
        case .food: "carrot"
        case .activities: "soccerball"
        case .travel: "airplane"
        case .objects: "lightbulb"
        case .symbols: "heart"
        case .flags: "flag"
        }
    }
}

public struct Emoji: Hashable, Sendable {
    public let character: String
    public let section: EmojiSection
    public let englishName: String
    public let russianName: String
    /// Слова названий и ключевых слов обоих языков — строчные, «ё» как «е».
    let words: [String]
}

/// Все эмодзи по разделам и поиск по ним. Данные — ресурс `emoji.tsv` (scripts/emoji/build-emoji-data.py):
/// строка — раздел, эмодзи, английское название, английские слова через «|», русское название, русские слова.
public final class EmojiCatalog: Sendable {
    public static let shared = EmojiCatalog(tsv: loadResource())

    public let all: [Emoji]
    private let bySection: [EmojiSection: [Emoji]]
    private let byCharacter: [String: Emoji]

    init(tsv: String) {
        var emojis: [Emoji] = []
        for line in tsv.split(separator: "\n") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count == 6, let section = EmojiSection(rawValue: columns[0]), section != .recent else { continue }
            let texts = [columns[2], columns[4]] + columns[3].split(separator: "|").map(String.init)
                + columns[5].split(separator: "|").map(String.init)
            emojis.append(Emoji(character: columns[1], section: section, englishName: columns[2], russianName: columns[4],
                                words: Array(Set(texts.flatMap(Self.words)))))
        }
        all = emojis
        bySection = Dictionary(grouping: emojis, by: \.section)
        byCharacter = Dictionary(emojis.map { ($0.character, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func emojis(in section: EmojiSection) -> [Emoji] {
        bySection[section] ?? []
    }

    public func emoji(_ character: String) -> Emoji? {
        byCharacter[character]
    }

    /// Эмодзи, у которых каждое слово запроса — начало какого-нибудь их слова. Сначала те, чьё русское или
    /// английское название начинается с запроса; дальше — в порядке разделов. Пустой запрос — пусто.
    public func search(_ query: String) -> [Emoji] {
        let normalized = Self.normalize(query).trimmingCharacters(in: .whitespaces)
        let queryWords = Self.words(normalized)
        guard !queryWords.isEmpty else { return [] }
        let found = all.filter { emoji in
            queryWords.allSatisfy { word in emoji.words.contains { $0.hasPrefix(word) } }
        }
        let leading = found.filter { Self.normalize($0.russianName).hasPrefix(normalized) || Self.normalize($0.englishName).hasPrefix(normalized) }
        let leadingSet = Set(leading)
        return leading + found.filter { !leadingSet.contains($0) }
    }

    public func random(using generator: inout some RandomNumberGenerator) -> Emoji {
        all.randomElement(using: &generator)!
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func words(_ text: String) -> [String] {
        normalize(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func loadResource() -> String {
        guard let url = Bundle.module.url(forResource: "emoji", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }
}

/// «Недавние» — последние 16 выбранных эмодзи, последний первым; хранятся на этом Mac.
public final class RecentEmojis: @unchecked Sendable {
    public static let limit = 16
    private static let key = "recentEmojis"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var emojis: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    public func add(_ emoji: String) {
        let list = [emoji] + emojis.filter { $0 != emoji }
        defaults.set(Array(list.prefix(Self.limit)), forKey: Self.key)
    }
}
