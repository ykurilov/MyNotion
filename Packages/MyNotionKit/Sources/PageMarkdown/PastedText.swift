import Foundation
import NotesCore

/// Текст другой программы при ⌘V → блоки страницы: Markdown ответов ИИ (кнопка «Копировать» Claude, ChatGPT),
/// отрисованный HTML (ответ чата или страница, выделенные мышью) и обычный текст со строками-списками.
/// Разбор тот же, что у `mynotion page write` (`MarkdownBlocksBuilder`), только без файлов с диска и ссылок на страницы.
public enum PastedText {
    /// `nil` — вставлять как раньше, текстом в строку: одна строка или текст без Markdown, списков и строения в HTML.
    /// `html` — HTML буфера: главнее простого текста, если в нём есть строение (заголовок, список, цитата, код
    /// рядом с текстом, таблица, разделитель); HTML-обёртка простого текста (редактор кода) уступает его Markdown.
    /// `hasRichText` — в буфере есть и оформленный текст (HTML, RTF). Тогда из простого текста блоками — только явный
    /// Markdown: простой текст страницы бывает со строками «1.», а оформление лучше возьмёт вставка с оформлением.
    public static func blocks(from text: String, html: String? = nil, pageId: UUID, hasRichText: Bool) -> [Block]? {
        if let html, let blocks = structuredBlocks(fromHTML: html, pageId: pageId) { return blocks }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard lines.filter({ !isBlank($0) }).count > 1 else { return nil }
        let markdown: String
        if lines.contains(where: isExplicitMarkdown) || (!hasRichText && lines.contains { markdownListItem.matches($0) }) {
            markdown = lines.map(withMarkdownMarker).joined(separator: "\n")
        } else if !hasRichText, lines.contains(where: { plainListItem.matches($0) }) {
            markdown = plainMarkdown(lines)
        } else {
            return nil
        }
        let blocks = blocks(fromMarkdown: markdown, pageId: pageId)
        return blocks.contains { $0.containerId == nil } ? blocks : nil
    }

    /// Блоки HTML, если в нём есть строение и их больше одного; абзацы без строения — `nil`: Word, Pages и Заметки
    /// вставляет с оформлением прежняя вставка, а Markdown внутри HTML-обёртки читается из простого текста.
    private static func structuredBlocks(fromHTML html: String, pageId: UUID) -> [Block]? {
        let blocks = blocks(fromMarkdown: PastedHTML.markdown(from: html), pageId: pageId)
        let flow = blocks.filter { $0.containerId == nil }
        guard flow.count > 1, flow.contains(where: { $0.kind != .paragraph }) else { return nil }
        return blocks
    }

    private static func blocks(fromMarkdown markdown: String, pageId: UUID) -> [Block] {
        let builder = MarkdownBlocksBuilder(attachments: nil, baseFolder: nil, linkTarget: { _ in nil })
        // Пустые строки — только разделители абзацев: пустых абзацев вставка не добавляет.
        return builder.blocks(fromMarkdown: markdown, pageId: pageId).blocks.filter { block in
            !(block.kind == .paragraph && block.containerId == nil && block.text.string.isEmpty && block.props.isEmpty)
        }.map(withWebLinksOnly)
    }

    /// Ссылки — только http, https и mailto, как у HTML (`PastedHTML`): `file:` и `javascript:` остаются текстом.
    private static func withWebLinksOnly(_ block: Block) -> Block {
        var block = block
        block.text.runs.removeAll { run in
            guard case .link(let url) = run.style else { return false }
            return !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        }
        return block
    }

    // MARK: Признаки

    private struct LinePattern {
        let regex: NSRegularExpression

        init(_ pattern: String) { regex = try! NSRegularExpression(pattern: pattern) }

        func matches(_ line: String) -> Bool {
            regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
    }

    /// Строки, которых в простом тексте не бывает: заголовок, код, цитата, строка таблицы, чекбокс, оформление в строке.
    nonisolated(unsafe) private static let explicitMarkdown = [
        LinePattern(#"^ {0,3}#{1,6}[ \t]+\S"#),
        LinePattern(#"^\s*(```|~~~)"#),
        LinePattern(#"^ {0,3}>"#),
        LinePattern(#"^\s*\|.*\|\s*$"#),
        LinePattern(#"^\s*[-*+][ \t]+\[[ xX]\]"#),
        LinePattern(#"\*\*[^*\s][^*]*\*\*|__[^_\s][^_]*__"#),
        LinePattern(#"`[^`]+`"#),
        LinePattern(#"~~[^~\s][^~]*~~"#),
        LinePattern(#"\[[^\]]+\]\([^)\s]+\)"#),
    ]

    private static func isExplicitMarkdown(_ line: String) -> Bool {
        explicitMarkdown.contains { $0.matches(line) }
    }

    /// `- пункт`, `* пункт`, `+ пункт`, `1. пункт`, `1) пункт`.
    nonisolated(unsafe) private static let markdownListItem = LinePattern(#"^\s*([-*+]|\d{1,9}[.)])[ \t]+\S"#)
    /// Знаки списков обычного текста: `• пункт` и подобные. Тире — нет: им начинаются реплики диалога.
    nonisolated(unsafe) private static let plainListItem = LinePattern(#"^\s*[•◦▪‣·][ \t]+\S"#)
    nonisolated(unsafe) private static let plainMarker = try! NSRegularExpression(pattern: #"^(\s*)[•◦▪‣·][ \t]+"#)
    nonisolated(unsafe) private static let anyMarker = try! NSRegularExpression(pattern: #"^(\s*)([-*+•◦▪‣·]|\d{1,9}[.)])[ \t]+"#)

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Знак списка обычного текста — знаком Markdown `- `.
    private static func withMarkdownMarker(_ line: String) -> String {
        plainMarker.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "$1- ")
    }

    /// Обычный текст — Markdown, в котором каждая строка — свой блок, а знаки текста (`*`, `_`, `#`) ничего не значат:
    /// пункт списка — знак и текст, остальное — абзац; знаки препинания экранированы.
    private static func plainMarkdown(_ lines: [String]) -> String {
        lines.filter { !isBlank($0) }.map { line in
            let range = NSRange(location: 0, length: (line as NSString).length)
            if let match = anyMarker.firstMatch(in: line, range: range) {
                let indent = (line as NSString).substring(with: match.range(at: 1))
                let marker = (line as NSString).substring(with: match.range(at: 2))
                let rest = (line as NSString).substring(from: NSMaxRange(match.range))
                let markdownMarker = marker.first?.isNumber == true ? marker : "-"
                return indent + markdownMarker + " " + escaped(rest)
            }
            return escaped(line.trimmingCharacters(in: .whitespaces))
        }.joined(separator: "\n\n")
    }

    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if character.isASCII, character.isPunctuation || character.isSymbol { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
