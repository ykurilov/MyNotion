import Foundation
import NotesCore

/// Строка Markdown → текст с оформлением тем же разбором, что импорт Notion (005: `text` блока и ячейки в командах).
public enum InlineMarkdownReader {
    /// Ссылка на файл выгрузки (`Страница.md`) здесь не страница: остаётся её названием без ссылки.
    public static func inlineText(_ markdown: String) -> InlineText {
        let result = NotionInlineParser.parse(markdown)
        guard !result.pageMentions.isEmpty else { return result.text }
        let titles = Dictionary(result.pageMentions.map { ($0.placeholder, $0.title) }) { first, _ in first }
        var string = ""
        var runs: [StyledRun] = []
        var shift = 0
        var units = Array(result.text.string.utf16)
        var replacements: [(at: Int, title: [UInt16])] = []
        for run in result.text.runs {
            guard case .mention(let id) = run.style, let title = titles[id] else { continue }
            replacements.append((run.start, Array(title.utf16)))
        }
        // Знак упоминания → название; отрезки за ним сдвигаются.
        for replacement in replacements.sorted(by: { $0.at > $1.at }) {
            units.replaceSubrange(replacement.at..<(replacement.at + 1), with: replacement.title)
        }
        string = String(decoding: units, as: UTF16.self)
        for run in result.text.runs {
            if case .mention(let id) = run.style, titles[id] != nil { continue }
            shift = replacements.filter { $0.at < run.start }.reduce(0) { $0 + $1.title.count - 1 }
            let inside = replacements.filter { $0.at >= run.start && $0.at < run.start + run.length }.reduce(0) { $0 + $1.title.count - 1 }
            runs.append(StyledRun(start: run.start + shift, length: run.length + inside, style: run.style))
        }
        return InlineText(string, runs: runs).normalized()
    }
}
