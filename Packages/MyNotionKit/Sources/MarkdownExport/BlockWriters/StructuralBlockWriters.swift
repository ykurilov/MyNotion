import Foundation
import NotesCore

/// Переключатель, цитата, выноска, разделитель в Markdown (contracts/markdown-and-notion.md, «Блоки»):
/// чего нет в Markdown — тегом, как пишет Notion; свёрнутость не пишется.

/// `<details>`, `<summary>текст</summary>`, дети Markdown между пустыми строками, `</details>`.
struct ToggleWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.toggle] }
    var writesChildren: Bool { true }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        // В строке тега перенос — `<br>`: перевод строки закрыл бы `<summary>`.
        let summary = InlineMarkdown.render(block.text).replacingOccurrences(of: "\n", with: "<br>")
        return ["<details>", "<summary>\(summary)</summary>"] + (children.isEmpty ? [] : [""] + children + [""]) + ["</details>"]
    }
}

/// `> текст`; дети — строками `> ` с их Markdown, через пустую строку цитаты `>`.
struct QuoteWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.quote] }
    var writesChildren: Bool { true }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        let text = StructuralBlockText.lines(InlineMarkdown.render(block.text))
        let quoted = text.isEmpty ? [">"] : text.map { "> " + $0 }
        return quoted + (children.isEmpty ? [] : [">"] + children.map { $0.isEmpty ? ">" : "> " + $0 })
    }
}

/// `<aside data-icon="💡">`, пустая строка, текст и дети Markdown, пустая строка, `</aside>`.
struct CalloutWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.callout] }
    var writesChildren: Bool { true }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        let icon = block.props.icon ?? BlockProps.defaults(for: .callout).icon ?? "💡"
        let text = StructuralBlockText.lines(InlineMarkdown.render(block.text))
        var lines = ["<aside data-icon=\"\(icon.replacingOccurrences(of: "\"", with: "&quot;"))\">", ""]
        if !text.isEmpty { lines += text + [""] }
        if !children.isEmpty { lines += children + [""] }
        return lines + ["</aside>"]
    }
}

/// `---`.
struct DividerWriter: MarkdownBlockKindWriter {
    var kinds: Set<BlockKind> { [.divider] }

    func lines(for block: Block, children: [String], context: MarkdownWriteContext) -> [String]? {
        ["---"]
    }
}

enum StructuralBlockText {
    /// Текст блока по строкам: перенос внутри блока — два пробела в конце строки, как у абзаца.
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let parts = text.components(separatedBy: "\n")
        return parts.enumerated().map { index, part in part + (index < parts.count - 1 ? "  " : "") }
    }
}
