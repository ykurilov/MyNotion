import Foundation
import NotesCore

/// Код, формула-блок и оглавление в Markdown (contracts/markdown-and-notion.md, «Блоки»); формула в строке — «В строке».

/// ```` ```swift ```` … ```` ``` ````; язык `plain` — без названия; внутри три «`» подряд — ограда длиннее самой длинной серии.
struct CodeWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.code] }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        let code = block.text.string
        var longest = 0
        var run = 0
        for character in code {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let language = block.props.language.flatMap { $0 == "plain" ? nil : $0 } ?? ""
        return [fence + language] + (code.isEmpty ? [] : code.components(separatedBy: "\n")) + [fence]
    }
}

/// `$$`, запись, `$$`.
struct EquationWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.equation] }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        ["$$"] + block.text.string.components(separatedBy: "\n") + ["$$"]
    }
}

/// `<nav data-toc></nav>`.
struct TableOfContentsWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.tableOfContents] }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        ["<nav data-toc></nav>"]
    }
}

/// Формула в строке: `$запись$`. Рядом цифра, `$` в записи или пробел с края — `<span data-equation>запись</span>`:
/// иначе читалка Markdown примет её за деньги или не найдёт конец.
enum EquationMarkdown {
    static func inline(_ latex: String, before: UInt16?, after: UInt16?) -> String {
        let isDigit: (UInt16?) -> Bool = { $0.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
        let needsTag = latex.isEmpty || latex.contains("$") || latex.first?.isWhitespace == true || latex.last?.isWhitespace == true
            || latex.contains("\n") || isDigit(before) || isDigit(after)
        guard needsTag else { return "$" + latex + "$" }
        let escaped = latex.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<span data-equation>\(escaped)</span>"
    }
}
