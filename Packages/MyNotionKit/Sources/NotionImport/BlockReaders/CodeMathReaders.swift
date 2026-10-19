import CodeHighlighting
import Foundation
import NotesCore

/// Код, формула-блок и оглавление из Markdown Notion и нашей выгрузки (contracts/markdown-and-notion.md):
/// ограда ```` ```язык ````, `$$ … $$`, `<nav data-toc>`.

/// ```` ```язык ```` или `~~~язык` … закрывающая ограда — блок кода с языком. Незнакомый язык — «Простой текст»,
/// а имя языка — в отчёт.
struct CodeReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        let line = lines[index]
        let indentation = NotionMarkdownParser.leadingSpaces(line)
        guard indentation <= 3, let (fence, info) = Self.opening(line.trimmingCharacters(in: .whitespaces)) else { return nil }
        var code: [String] = []
        var next = index + 1
        while next < lines.endIndex {
            let candidate = lines[next]
            next += 1
            if Self.closes(candidate, fence: fence) { break }
            code.append(String(candidate.dropFirst(min(indentation, NotionMarkdownParser.leadingSpaces(candidate)))))
        }
        var props = BlockProps.defaults(for: .code)
        var unknown: [String] = []
        if !info.isEmpty {
            // Notion пишет «plain text» с пробелом; у остальных первое слово — язык.
            let language = LanguageDefinition.named(info) ?? info.split(separator: " ").first.flatMap { LanguageDefinition.named(String($0)) }
            if let language { props.language = language.id } else { unknown.append(info) }
        }
        let block = ParsedBlock(kind: .code, text: InlineText(code.joined(separator: "\n")), props: props)
        return NotionBlockReading(blocks: [block], nextIndex: next, unknownCodeLanguages: unknown)
    }

    /// Ограда и имя языка за ней; у «```» в строке открытия не бывает обратных кавычек дальше — иначе это код в строке.
    static func opening(_ trimmed: String) -> (fence: String, info: String)? {
        guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
        let length = trimmed.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces)
        if marker == "`", info.contains("`") { return nil }
        return (String(repeating: marker, count: length), info)
    }

    /// Закрывающая ограда: те же знаки, не короче, и больше ничего в строке.
    static func closes(_ line: String, fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = fence.first, trimmed.hasPrefix(fence) else { return false }
        return trimmed.allSatisfy { $0 == marker }
    }
}

/// `$$`, запись в строках, `$$` (или `$$запись$$` одной строкой) — формула-блок.
struct EquationReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard NotionMarkdownParser.leadingSpaces(lines[index]) <= 3, trimmed.hasPrefix("$$") else { return nil }
        if trimmed.count > 4, trimmed.hasSuffix("$$") {
            let latex = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
            return NotionBlockReading(blocks: [ParsedBlock(kind: .equation, text: InlineText(latex))], nextIndex: index + 1)
        }
        var formula: [String] = []
        let first = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if !first.isEmpty { formula.append(first) }
        var next = index + 1
        while next < lines.endIndex {
            let candidate = lines[next].trimmingCharacters(in: .whitespaces)
            next += 1
            if candidate.hasSuffix("$$") {
                let last = candidate.dropLast(2).trimmingCharacters(in: .whitespaces)
                if !last.isEmpty { formula.append(last) }
                break
            }
            formula.append(candidate)
        }
        return NotionBlockReading(blocks: [ParsedBlock(kind: .equation, text: InlineText(formula.joined(separator: "\n")))], nextIndex: next)
    }
}

/// `<nav data-toc></nav>` — оглавление.
struct TableOfContentsReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("<nav"), trimmed.contains("data-toc") else { return nil }
        var next = index + 1
        if !trimmed.hasSuffix("</nav>") {
            while next < lines.endIndex, !lines[next].lowercased().contains("</nav>") { next += 1 }
            next = min(next + 1, lines.endIndex)
        }
        return NotionBlockReading(blocks: [ParsedBlock(kind: .tableOfContents)], nextIndex: next)
    }
}

extension NotionSimplification {
    /// Строка отчёта о языках кода, которых MyNotion не знает.
    public static func unknownCodeLanguagesTitle(_ names: [String]) -> String {
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let noun = unique.count > 1 ? "блоки кода на незнакомых языках" : "блоки кода на незнакомом языке"
        return "\(noun) (\(unique.joined(separator: ", "))) — показаны простым текстом"
    }
}
