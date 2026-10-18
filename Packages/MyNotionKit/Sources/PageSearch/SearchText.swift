import Foundation

/// Как текст попадает в индекс и как разбирается запрос: «ё» = «е», регистр не важен, слово ищется по началу.
/// Индекс сам приводит регистр и снимает надстрочные знаки (`unicode61 remove_diacritics 2`); здесь — то, чего он не делает.
enum SearchText {
    /// Текст для индекса. То же правило — в миграции v4 (`SchemaMigrations.fillSearchIndex`).
    static func indexed(_ text: String) -> String {
        text.replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "Ё", with: "Е")
    }

    /// Слова запроса в виде для сравнения; знаки препинания и операторы FTS — разделители.
    static func queryWords(_ query: String) -> [String] {
        query.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(comparable)
    }

    /// Запрос FTS5: каждое слово — по началу, все обязательны.
    static func ftsQuery(_ words: [String]) -> String {
        words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Слово в виде для сравнения: без регистра и надстрочных знаков, «ё» = «е».
    static func comparable(_ word: String) -> String {
        indexed(word).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Где в `text` начинаются слова на одно из `words`: начало слова длиной в найденную часть.
    static func highlights(of words: [String], in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, wordRange, _, _ in
            guard let word else { return }
            let folded = comparable(word)
            guard let match = words.filter({ folded.hasPrefix($0) }).max(by: { $0.count < $1.count }) else { return }
            let end = text.index(wordRange.lowerBound, offsetBy: min(match.count, word.count))
            ranges.append(NSRange(wordRange.lowerBound..<end, in: text))
        }
        return ranges
    }
}
