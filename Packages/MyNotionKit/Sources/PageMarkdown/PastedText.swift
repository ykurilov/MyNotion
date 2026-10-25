import Foundation
import NotesCore

/// Текст другой программы при ⌘V → блоки страницы: Markdown ответов ИИ (кнопка «Копировать» Claude, ChatGPT)
/// и обычный текст со строками-списками. Разбор тот же, что у `mynotion page write` (`MarkdownBlocksBuilder`),
/// только без файлов с диска и ссылок на страницы.
public enum PastedText {
    /// `nil` — вставлять как раньше, текстом в строку: одна строка или обычный текст без Markdown и списков.
    /// `hasRichText` — в буфере есть и оформленный текст (HTML, RTF). Тогда блоками — только явный Markdown:
    /// простой текст страницы браузера тоже бывает со строками «1.», а оформление лучше взять из HTML.
    public static func blocks(from text: String, pageId: UUID, hasRichText: Bool) -> [Block]? {
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
        let builder = MarkdownBlocksBuilder(attachments: nil, baseFolder: nil, linkTarget: { _ in nil })
        // Пустые строки — только разделители абзацев: пустых абзацев вставка не добавляет.
        let blocks = builder.blocks(fromMarkdown: markdown, pageId: pageId).blocks.filter { block in
            !(block.kind == .paragraph && block.containerId == nil && block.text.string.isEmpty && block.props.isEmpty)
        }
        return blocks.contains { $0.containerId == nil } ? blocks : nil
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
    /// Знаки списков обычного текста: `• пункт`, `— пункт` и подобные.
    nonisolated(unsafe) private static let plainListItem = LinePattern(#"^\s*[•◦▪‣·—–][ \t]+\S"#)
    nonisolated(unsafe) private static let plainMarker = try! NSRegularExpression(pattern: #"^(\s*)[•◦▪‣·—–][ \t]+"#)
    nonisolated(unsafe) private static let anyMarker = try! NSRegularExpression(pattern: #"^(\s*)([-*+•◦▪‣·—–]|\d{1,9}[.)])[ \t]+"#)

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
