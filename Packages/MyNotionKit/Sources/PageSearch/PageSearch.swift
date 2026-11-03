import Foundation
import GRDB
import NotesCore

/// Поиск страниц по слову (FR-018, research R6): запрос к `search_index`, сначала совпадения в названии,
/// потом в тексте. Страницы, которых нет в дереве (корзина вместе с подстраницами), в выдачу не попадают.
/// Строки баз и страницы внутри строк (004, research R14) в дереве панели не лежат: их путь до базы читается из базы,
/// шаблоны строк и всё в корзине отсекаются. Совпадение в значении свойства — без блока, кусок текста — само значение.
public struct PageSearch: Sendable {
    /// Сколько страниц показывает выдача.
    public static let defaultLimit = 20
    /// Длина куска текста с найденным словом, без «…» по краям.
    public static let snippetLength = 80
    /// Сколько знаков текста оставить перед найденным словом.
    static let snippetLeadingContext = 24
    /// Сколько найденных названий разбирать: часть может оказаться в корзине.
    static let titleCandidateLimit = 200

    private let store: NotesStore

    public init(store: NotesStore) {
        self.store = store
    }

    /// Страницы, где все слова запроса есть в названии или в одном блоке. `tree` — видимое дерево: из него
    /// берутся название, иконка и путь родителей, по нему отсекается корзина.
    public func results(for query: String, in tree: PageTreeSnapshot, limit: Int = defaultLimit) throws -> [PageSearchResult] {
        let words = SearchText.queryWords(query)
        guard !words.isEmpty else { return [] }

        let match = SearchText.ftsQuery(words)
        let (titleMatches, textMatches, located) = try store.database.dbWriter.read { db in
            var located = FoundPages(tree: tree)
            // Названия — строки с отрицательным rowid: их мало, они упорядочены по близости к запросу.
            let titleMatches = try String.fetchAll(db, sql: """
                SELECT pageId FROM search_index WHERE search_index MATCH ? AND rowid < 0 ORDER BY rank LIMIT ?
                """, arguments: [match, Self.titleCandidateLimit])
                .compactMap(UUID.init(uuidString:))
                .filter { try located.locate($0, in: db) }
            var shown = Set(titleMatches.prefix(limit))
            // Текст — от новых блоков к старым, без упорядочивания всех совпадений: частое слово есть почти
            // в каждом блоке, а выдаче нужно лишь несколько страниц. Значение свойства — без блока, со своим текстом.
            var textMatches: [(pageId: UUID, match: TextMatch)] = []
            let rows = try Row.fetchCursor(db, sql: """
                SELECT pageId, blockId, content FROM search_index WHERE search_index MATCH ? AND rowid > 0 ORDER BY rowid DESC
                """, arguments: [match])
            while shown.count < limit, let row = try rows.next() {
                let blockText: String? = row["blockId"]
                let found: TextMatch? = if let blockText { UUID(uuidString: blockText).map(TextMatch.block) } else { .value(row["content"]) }
                guard let found, let pageId = UUID(uuidString: row["pageId"]), try located.locate(pageId, in: db),
                      shown.insert(pageId).inserted else { continue }
                textMatches.append((pageId, found))
            }
            return (Array(titleMatches.prefix(limit)), textMatches, located)
        }
        let titleMatchSet = Set(titleMatches)
        var bestMatchByPage: [UUID: TextMatch] = [:]
        for match in textMatches { bestMatchByPage[match.pageId] = match.match }
        let ordered = titleMatches + textMatches.map(\.pageId).filter { !titleMatchSet.contains($0) }

        let blockTexts = try texts(ofBlocks: ordered.compactMap { bestMatchByPage[$0]?.blockId })
        return ordered.compactMap { pageId in
            guard let page = located.entry(pageId) else { return nil }
            let text: String? = switch bestMatchByPage[pageId] {
            case .block(let blockId): blockTexts[blockId]
            case .value(let value): value
            case nil: nil
            }
            return PageSearchResult(
                pageId: pageId,
                title: page.title,
                icon: page.icon,
                path: located.pathTitles(of: pageId).map { $0.isEmpty ? Page.untitledTitle : $0 },
                titleHighlights: SearchText.highlights(of: words, in: page.title),
                snippet: text.map { Self.snippet(of: $0, around: words) },
                blockId: titleMatchSet.contains(pageId) ? nil : bestMatchByPage[pageId]?.blockId
            )
        }
    }

    /// Где нашлись слова: блок страницы или значение свойства строки (текст из индекса).
    private enum TextMatch {
        case block(UUID)
        case value(String)

        var blockId: UUID? {
            if case .block(let id) = self { id } else { nil }
        }
    }

    private func texts(ofBlocks ids: [UUID]) throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        return try store.database.dbWriter.read { db in
            var texts: [UUID: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, text FROM block WHERE id IN (\(marks))",
                                        arguments: StatementArguments(ids.map(\.searchIndexText))) {
                if let id = UUID(uuidString: row["id"]) { texts[id] = row["text"] }
            }
            return texts
        }
    }

    /// Кусок текста с первым найденным словом: начинается чуть раньше слова, с начала слова; обрезанное — «…».
    static func snippet(of text: String, around words: [String]) -> SearchSnippet {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let firstMatch = SearchText.highlights(of: words, in: flat).first.flatMap { Range($0, in: flat) }
        var start = flat.startIndex
        if let firstMatch {
            let wanted = flat.index(firstMatch.lowerBound, offsetBy: -snippetLeadingContext, limitedBy: flat.startIndex) ?? flat.startIndex
            start = wanted == flat.startIndex ? wanted : (flat[wanted...].firstIndex(of: " ").map { flat.index(after: $0) } ?? wanted)
            if start > firstMatch.lowerBound { start = firstMatch.lowerBound }
        }
        let end = flat.index(start, offsetBy: snippetLength, limitedBy: flat.endIndex) ?? flat.endIndex
        var piece = String(flat[start..<end])
        if start > flat.startIndex { piece = "…" + piece }
        if end < flat.endIndex { piece += "…" }
        return SearchSnippet(text: piece, highlights: SearchText.highlights(of: words, in: piece))
    }
}

/// Строка выдачи: страница, путь её родителей и кусок текста с найденным словом.
public struct PageSearchResult: Sendable, Hashable, Identifiable {
    public let pageId: UUID
    public let title: String
    public let icon: String?
    /// Названия родителей от корня.
    public let path: [String]
    /// Найденные части слов в названии.
    public let titleHighlights: [NSRange]
    /// `nil` — слово нашлось только в названии.
    public let snippet: SearchSnippet?
    /// Блок, где нашлись слова; переход к нему раскрывает свёрнутых предков (US1). `nil` — нашлось в названии.
    public var blockId: UUID? = nil

    public var id: UUID { pageId }
}

public struct SearchSnippet: Sendable, Hashable {
    public let text: String
    /// Найденные части слов в `text`.
    public let highlights: [NSRange]
}
