import Foundation
import NotesCore

/// Текст другой программы при ⌘V → блоки страницы: Markdown ответов ИИ (кнопка «Копировать» Claude, ChatGPT),
/// отрисованный HTML (ответ чата или страница, выделенные мышью) и обычный текст в несколько строк (списки — списками).
/// Разбор тот же, что у `mynotion page write` (`MarkdownBlocksBuilder`), только без файлов с диска и ссылок на страницы.
public enum PastedText {
    /// `nil` — вставлять как раньше, текстом в строку: одна строка или, рядом с оформленным текстом, текст без Markdown
    /// и строения в HTML. Обычный текст в несколько строк — абзацами, по блоку на строку.
    /// `html` — HTML буфера: главнее простого текста, если в нём есть строение (заголовок, список, цитата, код
    /// рядом с текстом, таблица, разделитель); HTML-обёртка простого текста (редактор кода) уступает его Markdown.
    /// `hasRichText` — в буфере есть и оформленный текст (HTML, RTF). Тогда из простого текста блоками — только явный
    /// Markdown: простой текст страницы бывает со строками «1.», а оформление лучше возьмёт вставка с оформлением.
    /// `webCustomData` — буфер Chromium (`org.chromium.web-custom-data`): у Notion в нём места пустых блоков и картинок.
    /// Картинка Notion встаёт блоком-картинкой без файла: в `url` — откуда скачать, в `title` — имя файла;
    /// скачивает её редактор после вставки.
    public static func blocks(from text: String, html: String? = nil, webCustomData: Data? = nil, pageId: UUID,
                              hasRichText: Bool) -> [Block]? {
        if let html, let webCustomData, let selection = NotionClipboard.selectedBlocks(fromWebCustomData: webCustomData),
           let blocks = withNotionBlocks(selection, in: blocks(fromMarkdown: PastedHTML.markdown(from: html), pageId: pageId),
                                              pageId: pageId) {
            return blocks
        }
        if let html, let blocks = structuredBlocks(fromHTML: html, pageId: pageId) { return blocks }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { isBlankLine($0) ? "" : $0 }
        guard lines.filter({ !isBlankLine($0) }).count > 1 else { return nil }
        let markdown: String
        if lines.contains(where: isExplicitMarkdown) || (!hasRichText && lines.contains { markdownListItem.matches($0) }) {
            markdown = lines.map(withMarkdownMarker).joined(separator: "\n")
        } else if !hasRichText, lines.contains(where: { plainListItem.matches($0) }) {
            markdown = plainMarkdown(lines)
        } else if !hasRichText {
            // Обычный текст, как у Notion: каждая строка — свой абзац, пустые строки — только разделители.
            // Без разбора Markdown: знаки текста ничего не значат, а длинный текст (песня) вставляется быстро.
            return lines.filter { !isBlankLine($0) }.map { line in
                Block(pageId: pageId, text: InlineText(line.trimmingCharacters(in: .whitespaces)), sortKey: .between(nil, nil))
            }
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

    /// Блоки HTML Notion с пустыми абзацами и картинками на местах пустых блоков и картинок выделения. Верхние блоки
    /// HTML — по одному на каждый текстовый верхний блок выделения, вложенные идут со своим верхним. `nil` — пустых
    /// блоков и картинок нет или блоки не сходятся по числу: тогда вставка как без Notion.
    private static func withNotionBlocks(_ selection: [NotionClipboard.Entry], in blocks: [Block], pageId: UUID) -> [Block]? {
        let texts = selection.count { if case .text = $0 { true } else { false } }
        guard texts < selection.count else { return nil }
        let flow = blocks.indices.filter { blocks[$0].containerId == nil }
        let topIndent = flow.map { blocks[$0].indent }.min() ?? 0
        let tops = flow.filter { blocks[$0].indent == topIndent }
        guard tops.count == texts else { return nil }
        // Куски вставки по верхним блокам: верхний со своими вложенными и содержимым таблиц.
        let pieces = tops.enumerated().map { position, start in
            Array(blocks[start..<(position + 1 < tops.count ? tops[position + 1] : blocks.endIndex)])
        }
        var result = Array(blocks[..<(tops.first ?? blocks.endIndex)])
        var next = pieces.makeIterator()
        for entry in selection {
            switch entry {
            case .empty:
                result.append(Block(pageId: pageId, indent: topIndent, sortKey: .between(nil, nil)))
            case .image(let url, let name):
                var props = BlockProps()
                props.url = url
                props.title = name
                result.append(Block(pageId: pageId, kind: .image, indent: topIndent, sortKey: .between(nil, nil), props: props))
            case .text:
                if let piece = next.next() { result.append(contentsOf: piece) }
            }
        }
        return result
    }

    private static func blocks(fromMarkdown markdown: String, pageId: UUID) -> [Block] {
        let builder = MarkdownBlocksBuilder(attachments: nil, baseFolder: nil, linkTarget: { _ in nil })
        // Пустые строки — только разделители абзацев: пустых абзацев вставка не добавляет.
        return builder.blocks(fromMarkdown: markdown, pageId: pageId).blocks.filter { block in
            !(block.kind == .paragraph && block.containerId == nil && isBlankLine(block.text.string) && block.props.isEmpty)
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

    /// Строка без видимых знаков: пробелы, табуляция, неразрывный и нулевой ширины пробелы.
    public static func isBlankLine(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy { $0.properties.isWhitespace || invisibleScalars.contains($0) }
    }

    private static let invisibleScalars: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]

    /// Знак списка обычного текста — знаком Markdown `- `.
    private static func withMarkdownMarker(_ line: String) -> String {
        plainMarker.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "$1- ")
    }

    /// Обычный текст — Markdown, в котором каждая строка — свой блок, а знаки текста (`*`, `_`, `#`) ничего не значат:
    /// пункт списка — знак и текст, остальное — абзац; знаки препинания экранированы.
    private static func plainMarkdown(_ lines: [String]) -> String {
        lines.filter { !isBlankLine($0) }.map { line in
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
