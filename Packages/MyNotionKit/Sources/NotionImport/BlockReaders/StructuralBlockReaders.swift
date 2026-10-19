import Foundation
import NotesCore

/// Переключатель, выноска, цитата, разделитель из Markdown Notion и нашей выгрузки (contracts/markdown-and-notion.md):
/// `<details>`/`<summary>`, `<aside>` (иконка — `data-icon` или эмодзи в начале текста), `>` с детьми, `---`.

/// `<details>` … `</details>` с `<summary>` — переключатель; всё внутри — его дети.
struct ToggleReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        guard StructuralMarkup.opens("details", lines[index]),
              let (body, next) = StructuralMarkup.element("details", in: lines, at: index) else { return nil }
        var inner = body
        var summary = ""
        if let first = inner.firstIndex(where: { !NotionMarkdownParser.isBlank($0) }),
           inner[first].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("<summary") {
            summary = inner[first].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"</?summary[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            inner.removeSubrange(...first)
        }
        let parsed = NotionMarkdownParser.blocks(in: inner)
        let toggle = ParsedBlock(kind: .toggle, text: NotionInlineParser.parse(summary.trimmingCharacters(in: .whitespaces)).text)
        return NotionBlockReading(blocks: [toggle] + StructuralMarkup.nested(parsed.blocks), nextIndex: next,
                                  simplifications: parsed.simplifications)
    }
}

/// `<aside>` … `</aside>` — выноска: первый абзац — её текст, остальное — дети.
struct CalloutReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        guard StructuralMarkup.opens("aside", lines[index]),
              let (body, next) = StructuralMarkup.element("aside", in: lines, at: index) else { return nil }
        let opening = lines[index].trimmingCharacters(in: .whitespaces)
        var icon = opening.range(of: #"data-icon="([^"]*)""#, options: .regularExpression)
            .map { String(opening[$0].dropFirst("data-icon=\"".count).dropLast()).replacingOccurrences(of: "&quot;", with: "\"") }
        let parsed = NotionMarkdownParser.blocks(in: body)
        var blocks = parsed.blocks
        var text = InlineText.empty
        if let first = blocks.first, first.kind == .paragraph {
            text = first.text
            blocks.removeFirst()
            // Notion пишет иконку первым знаком текста: «💡 Совет».
            if icon == nil {
                let (emoji, rest) = NotionMarkdownParser.splitIcon(text.string)
                if let emoji {
                    icon = emoji
                    text = StructuralMarkup.dropping(prefixUTF16: (text.string as NSString).length - (rest as NSString).length, from: text)
                }
            }
        }
        var props = BlockProps.defaults(for: .callout)
        if let icon, !icon.isEmpty { props.icon = icon }
        let callout = ParsedBlock(kind: .callout, text: text, color: .defaults(for: .callout), props: props)
        return NotionBlockReading(blocks: [callout] + StructuralMarkup.nested(blocks), nextIndex: next,
                                  simplifications: parsed.simplifications)
    }
}

/// Строки `>` подряд — цитата: первый абзац — её текст, остальное — дети.
struct QuoteReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        guard Self.isQuoteLine(lines[index]) else { return nil }
        var inner: [String] = []
        var next = index
        while next < lines.endIndex, Self.isQuoteLine(lines[next]) {
            let trimmed = lines[next].drop { $0 == " " || $0 == "\t" }.dropFirst()
            inner.append(String(trimmed.first == " " ? trimmed.dropFirst() : trimmed))
            next += 1
        }
        let parsed = NotionMarkdownParser.blocks(in: inner)
        var blocks = parsed.blocks
        var text = InlineText.empty
        if let first = blocks.first, first.kind == .paragraph || first.kind == .pageLink {
            text = first.text
            blocks.removeFirst()
        }
        return NotionBlockReading(blocks: [ParsedBlock(kind: .quote, text: text)] + StructuralMarkup.nested(blocks), nextIndex: next,
                                  simplifications: parsed.simplifications)
    }

    private static func isQuoteLine(_ line: String) -> Bool {
        NotionMarkdownParser.leadingSpaces(line) <= 3 && line.drop { $0 == " " }.first == ">"
    }
}

/// `---`, `***`, `___` — разделитель.
struct DividerReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        let line = lines[index]
        guard NotionMarkdownParser.leadingSpaces(line) <= 3,
              PageBuilder.isThematicBreak(line.trimmingCharacters(in: .whitespaces)) else { return nil }
        return NotionBlockReading(blocks: [ParsedBlock(kind: .divider)], nextIndex: index + 1)
    }
}

enum StructuralMarkup {
    /// Строка открывает тег `name` (`<details>`, `<aside data-icon="…">`).
    static func opens(_ name: String, _ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.hasPrefix("<" + name) else { return false }
        let after = trimmed.dropFirst(name.count + 1).first
        return after == nil || after == ">" || after == " "
    }

    /// Строки внутри тега `name` до парного закрывающего и строка после него; вложенные такие же теги считаются.
    /// Содержимое в строке открытия после `>` (Notion: `<details><summary>…`) — первая строка тела.
    static func element(_ name: String, in lines: ArraySlice<String>, at index: Int) -> (body: [String], next: Int)? {
        let closing = "</" + name + ">"
        var body: [String] = []
        let opening = lines[index].trimmingCharacters(in: .whitespaces)
        if let end = opening.firstIndex(of: ">") {
            let rest = String(opening[opening.index(after: end)...])
            if rest.lowercased().hasSuffix(closing) {
                let inner = String(rest.dropLast(closing.count))
                return (inner.isEmpty ? [] : [inner], index + 1)
            }
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty { body.append(rest) }
        }
        var depth = 1
        var current = index + 1
        while current < lines.endIndex {
            let line = lines[current]
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            if opens(name, line) { depth += 1 }
            if trimmed.hasSuffix(closing) {
                depth -= 1
                if depth == 0 {
                    let before = String(line.trimmingCharacters(in: .whitespaces).dropLast(closing.count))
                    if !before.trimmingCharacters(in: .whitespaces).isEmpty { body.append(before) }
                    return (body, current + 1)
                }
            }
            body.append(line)
            current += 1
        }
        return nil
    }

    /// Блоки внутри контейнера — на уровень глубже него.
    static func nested(_ blocks: [ParsedBlock]) -> [ParsedBlock] {
        blocks.map { block in
            var block = block
            block.indent = min(block.indent + 1, Block.indentRange.upperBound)
            return block
        }
    }

    /// Текст без первых `count` знаков UTF-16; оформление сдвигается.
    static func dropping(prefixUTF16 count: Int, from text: InlineText) -> InlineText {
        let string = (text.string as NSString).substring(from: min(count, (text.string as NSString).length))
        let runs = text.runs.compactMap { run -> StyledRun? in
            let start = max(run.start - count, 0)
            let end = run.start + run.length - count
            return end > start ? StyledRun(start: start, length: end - start, style: run.style) : nil
        }
        return InlineText(string, runs: runs).normalized()
    }
}
