import Foundation
import NotesCore

/// Markdown страницы для команд (005, research R7): чтение страницы — `PageMarkdownReader`, запись — `MarkdownBlocksBuilder`.
/// Страница в Markdown — ссылка `mynotion://page/<id>`: подстраница строкой `[Название](…)`, упоминание —
/// `[🚀 Название](…)` внутри строки.
public enum PageMarkdown {
    public static let pageScheme = "mynotion"

    public static func pageLink(_ id: UUID) -> String { "\(pageScheme)://page/\(id.uuidString.lowercased())" }

    /// Id страницы из `mynotion://page/<id>`.
    public static func pageId(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == pageScheme, url.host?.lowercased() == "page" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// Ссылки `mynotion://page/<id>` → упоминания: текст ссылки сворачивается в знак U+FFFC.
    public static func foldingPageLinks(in text: InlineText) -> InlineText {
        let links = text.runs.compactMap { run -> (range: Range<Int>, id: UUID)? in
            guard case .link(let url) = run.style, let id = pageId(from: url) else { return nil }
            return (run.start..<(run.start + run.length), id)
        }
        guard !links.isEmpty else { return text }
        var units = Array(text.string.utf16)
        var runs = text.runs.filter { run in
            if case .link(let url) = run.style, pageId(from: url) != nil { return false }
            return true
        }
        // С конца: сдвиг от свёрнутой ссылки не задевает ещё не обработанные слева.
        for link in links.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let range = link.range
            units.replaceSubrange(range, with: [InlineText.objectReplacementCharacter])
            let shrink = range.count - 1
            func moved(_ position: Int, isEnd: Bool) -> Int {
                if position <= range.lowerBound { return position }
                if position >= range.upperBound { return position - shrink }
                return range.lowerBound + (isEnd ? 1 : 0)
            }
            runs = runs.compactMap { run in
                let start = moved(run.start, isEnd: false), end = moved(run.start + run.length, isEnd: true)
                guard end > start, !(run.start >= range.lowerBound && run.start + run.length <= range.upperBound) else { return nil }
                return StyledRun(start: start, length: end - start, style: run.style)
            }
            runs.append(StyledRun(start: range.lowerBound, length: 1, style: .mention(link.id)))
        }
        return InlineText(String(decoding: units, as: UTF16.self), runs: runs).normalized()
    }
}

/// Что из Markdown перенесено не так, как написано (FR-414): строка с единицы, если она известна.
public struct PageMarkdownWarning: Sendable, Hashable {
    public var line: Int?
    public var message: String

    public init(line: Int?, message: String) {
        self.line = line
        self.message = message
    }
}
