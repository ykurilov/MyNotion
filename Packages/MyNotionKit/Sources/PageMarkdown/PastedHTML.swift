import Foundation

/// HTML буфера (ответ чата, выделенный мышью, страница браузера, заметка) → Markdown для `MarkdownBlocksBuilder`:
/// заголовки, списки и задачи с вложенностью, цитаты, код с языком, таблицы, разделитель и оформление в строке.
/// Стили, скрипты, кнопки и картинки отбрасываются, обёртки `div` и `span` — только границы абзацев.
enum PastedHTML {
    static func markdown(from html: String) -> String {
        let root = HTMLFragment.parse(html)
        var writer = MarkdownWriter()
        writer.write(contentsOf: root.first("body") ?? root)
        return writer.chunks.joined(separator: "\n\n")
    }
}

private struct MarkdownWriter {
    /// Блоки Markdown по порядку; между ними — пустая строка.
    private(set) var chunks: [String] = []
    /// Оформленный текст абзаца, который ещё собирается из строчных элементов.
    private var paragraph = ""
    /// Текст последнего абзаца без оформления: подпись языка над кодом в чатах не нужна отдельным абзацем.
    private var lastParagraphText: String?

    private static let skipped: Set<String> = ["head", "script", "style", "title", "meta", "link", "svg", "button", "template",
                                               "noscript", "iframe", "object", "img", "picture", "video", "audio", "canvas",
                                               "select", "textarea", "input", "math"]
    private static let blocks: Set<String> = ["p", "div", "section", "article", "main", "header", "footer", "aside", "nav", "figure",
                                              "figcaption", "details", "summary", "dl", "dt", "dd", "address", "center", "form",
                                              "fieldset", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre",
                                              "table", "hr", "body", "html"]
    private static let lists: Set<String> = ["ul", "ol"]

    mutating func write(contentsOf element: HTMLElement) {
        for child in element.children {
            switch child {
            case .text(let text): paragraph += Inline.text(text)
            case .element(let child) where Self.skipped.contains(child.name): continue
            case .element(let child) where Self.blocks.contains(child.name):
                flushParagraph()
                write(block: child)
            // Строчный тег вокруг блоков (Google Docs оборачивает весь документ в `<b>`) — просто обёртка.
            case .element(let child) where child.contains(Self.blocks): write(contentsOf: child)
            case .element(let child): paragraph += Inline.markdown(of: child)
            }
        }
        flushParagraph()
    }

    private mutating func write(block element: HTMLElement) {
        switch element.name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = min(Int(element.name.dropFirst()) ?? 3, 3)
            let text = Inline.lines(Inline.content(of: element)).joined(separator: " ")
            if !text.isEmpty { append(String(repeating: "#", count: level) + " " + text) }
        case "ul", "ol":
            var lines: [String] = []
            list(element, indent: 0, into: &lines)
            if !lines.isEmpty { append(lines.joined(separator: "\n")) }
        case "blockquote":
            var inner = MarkdownWriter()
            inner.write(contentsOf: element)
            let lines = inner.chunks.joined(separator: "\n").components(separatedBy: "\n")
            if inner.chunks.contains(where: { !$0.isEmpty }) { append(lines.map { "> " + $0 }.joined(separator: "\n")) }
        case "pre": code(element)
        case "table": table(element)
        case "hr": append("---")
        default: write(contentsOf: element)
        }
    }

    private mutating func append(_ chunk: String) {
        chunks.append(chunk)
        lastParagraphText = nil
    }

    private mutating func flushParagraph() {
        let lines = Inline.lines(paragraph)
        paragraph = ""
        guard !lines.isEmpty else { return }
        append(lines.joined(separator: "\n"))
        lastParagraphText = lines.joined(separator: "\n").replacingOccurrences(of: "\\", with: "")
    }

    // MARK: Списки

    /// Пункты с отступом вложенности: под пунктом — на ширину его знака, как читает разбор Markdown.
    private func list(_ element: HTMLElement, indent: Int, into lines: inout [String]) {
        var number = Int(element.attributes["start"] ?? "") ?? 1
        for item in element.elements {
            if Self.lists.contains(item.name) {
                list(item, indent: indent, into: &lines)
                continue
            }
            guard item.name == "li" else { continue }
            let parts = ListItemParts(item)
            let marker = switch parts.checked {
            case true?: "- [x] "
            case false?: "- [ ] "
            case nil: element.name == "ol" ? "\(number). " : "- "
            }
            number += 1
            let padding = String(repeating: " ", count: indent)
            let text = parts.lines.isEmpty ? [""] : parts.lines
            lines.append(padding + marker + text[0])
            lines += text.dropFirst().map { padding + String(repeating: " ", count: marker.count) + $0 }
            let markerWidth = parts.checked == nil ? marker.count : 2
            for nested in parts.nested { list(nested, indent: indent + markerWidth, into: &lines) }
        }
    }

    /// Пункт списка: текст (абзацы внутри — строками одного пункта), отметка задачи и вложенные списки.
    private struct ListItemParts {
        var lines: [String] = []
        var checked: Bool?
        var nested: [HTMLElement] = []

        init(_ item: HTMLElement) {
            var text = ""
            collect(item, into: &text)
            lines = Inline.lines(text)
        }

        private mutating func collect(_ element: HTMLElement, into text: inout String) {
            for child in element.children {
                switch child {
                case .text(let string): text += Inline.text(string)
                case .element(let child) where MarkdownWriter.lists.contains(child.name): nested.append(child)
                case .element(let child) where child.name == "input":
                    if checked == nil, child.attributes["type"]?.lowercased() == "checkbox" { checked = child.attributes["checked"] != nil }
                case .element(let child) where MarkdownWriter.skipped.contains(child.name): continue
                case .element(let child) where MarkdownWriter.blocks.contains(child.name):
                    text += "\n"
                    collect(child, into: &text)
                    text += "\n"
                case .element(let child): text += Inline.markdown(of: child)
                }
            }
        }
    }

    // MARK: Код и таблицы

    private mutating func code(_ pre: HTMLElement) {
        var code = pre.rawText
        if code.hasSuffix("\n") { code.removeLast() }
        while code.hasPrefix("\n") { code.removeFirst() }
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let language = Self.language(of: pre)
        if let language, let caption = lastParagraphText, caption.caseInsensitiveCompare(language) == .orderedSame {
            chunks.removeLast()
        }
        var fence = "```"
        while code.contains(fence) { fence += "`" }
        append(fence + (language ?? "") + "\n" + code + "\n" + fence)
    }

    /// `class="language-swift"` у `<code>` или `<pre>`, `lang-`, `highlight-source-` у обёртки GitHub, `data-language`.
    private static func language(of pre: HTMLElement) -> String? {
        for element in [pre.first("code"), pre].compactMap({ $0 }) {
            if let language = element.attributes["data-language"] ?? element.attributes["lang"], !language.isEmpty { return language }
            for name in element.classes {
                for prefix in ["language-", "lang-", "highlight-source-"] where name.hasPrefix(prefix) && name.count > prefix.count {
                    return String(name.dropFirst(prefix.count))
                }
            }
        }
        return nil
    }

    private mutating func table(_ table: HTMLElement) {
        var rows: [[String]] = []
        func collectRows(_ element: HTMLElement) {
            for child in element.elements {
                switch child.name {
                case "tr":
                    rows.append(child.elements.filter { $0.name == "td" || $0.name == "th" }.map { cell in
                        Inline.lines(Inline.content(of: cell)).joined(separator: " ")
                    })
                case "table": continue
                default: collectRows(child)
                }
            }
        }
        collectRows(table)
        rows = rows.filter { !$0.isEmpty }
        guard let width = rows.map(\.count).max(), width > 0 else { return }
        let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        let line = { (cells: [String]) in "| " + cells.joined(separator: " | ") + " |" }
        var lines = [line(padded[0]), line(Array(repeating: "---", count: width))]
        lines += padded.dropFirst().map(line)
        append(lines.joined(separator: "\n"))
    }
}

// MARK: Строчное оформление

/// Текст и оформление внутри строки: `**жирный**`, `*курсив*`, `` `код` ``, `~~зачёркнутый~~`, `[ссылка](адрес)`.
/// Знаки препинания текста экранированы — `*` и `#` в тексте страницы остаются знаками.
private enum Inline {
    /// Перевод строки `<br>` внутри абзаца, до разбивки на строки.
    static let lineBreak = "\u{2028}"

    private struct Style: OptionSet {
        let rawValue: Int
        static let bold = Style(rawValue: 1 << 0)
        static let italic = Style(rawValue: 1 << 1)
        static let strikethrough = Style(rawValue: 1 << 2)
    }

    /// Строки абзаца без лишних пробелов; пустые по краям — мимо.
    static func lines(_ markdown: String) -> [String] {
        let lines = markdown.replacingOccurrences(of: "\n", with: lineBreak).components(separatedBy: lineBreak).map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }), let last = lines.lastIndex(where: { !$0.isEmpty }) else { return [] }
        return lines[first...last].filter { !$0.isEmpty }
    }

    static func text(_ text: String) -> String {
        var result = ""
        for character in text {
            if character.isWhitespace || character == "\u{00A0}" {
                result.append(" ")
            } else {
                if character.isASCII, character.isPunctuation || character.isSymbol { result.append("\\") }
                result.append(character)
            }
        }
        return result
    }

    static func content(of element: HTMLElement) -> String {
        content(of: element, active: [])
    }

    static func markdown(of element: HTMLElement) -> String {
        markdown(of: element, active: [])
    }

    private static func content(of element: HTMLElement, active: Style) -> String {
        element.children.map { child in
            switch child {
            case .text(let string): text(string)
            case .element(let child): markdown(of: child, active: active)
            }
        }.joined()
    }

    private static func markdown(of element: HTMLElement, active: Style) -> String {
        switch element.name {
        case "br": return element.classes.contains("Apple-interchange-newline") ? "" : lineBreak
        case "code", "kbd", "samp", "tt": return code(element.rawText)
        case let name where ["script", "style", "svg", "button", "img", "input", "template", "noscript", "select", "textarea"].contains(name):
            return ""
        default: break
        }
        let style = self.style(of: element).subtracting(active)
        var inner = content(of: element, active: active.union(style))
        if style.contains(.strikethrough) { inner = wrap(inner, "~~") }
        if style.contains(.italic) { inner = wrap(inner, "*") }
        if style.contains(.bold) { inner = wrap(inner, "**") }
        if element.name == "a", let url = link(element.attributes["href"]) {
            let (lead, core, trail) = split(inner)
            return core.isEmpty ? inner : lead + "[" + core + "](" + url + ")" + trail
        }
        return inner
    }

    /// Оформление тега и его `style`: Google Docs оборачивает весь текст в `<b style="font-weight:normal">`.
    private static func style(of element: HTMLElement) -> Style {
        var style: Style = []
        let css = (element.attributes["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        let weight = css.firstMatch(of: /font-weight:([a-z0-9]+)/).map { String($0.output.1) }
        switch element.name {
        case "strong", "b": if weight != "normal" && weight != "400" { style.insert(.bold) }
        case "em", "i", "cite", "var": style.insert(.italic)
        case "s", "del", "strike": style.insert(.strikethrough)
        default: break
        }
        if let weight, weight == "bold" || weight == "bolder" || (Int(weight).map { $0 >= 600 } ?? false) { style.insert(.bold) }
        if css.contains("font-style:italic") { style.insert(.italic) }
        if css.contains("line-through") { style.insert(.strikethrough) }
        return style
    }

    private static func code(_ raw: String) -> String {
        let code = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !code.isEmpty else { return "" }
        var fence = "`"
        while code.contains(fence) { fence += "`" }
        let padding = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
        return fence + padding + code + padding + fence
    }

    /// Адрес ссылки для Markdown; якоря страницы и относительные пути — без ссылки.
    private static func link(_ href: String?) -> String? {
        guard let href = href?.trimmingCharacters(in: .whitespaces), let scheme = URL(string: href)?.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return href.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    /// Пробелы по краям — за знаки оформления: `** жирный **` Markdown не прочтёт.
    private static func wrap(_ text: String, _ marker: String) -> String {
        let (lead, core, trail) = split(text)
        return core.isEmpty ? text : lead + marker + core + marker + trail
    }

    private static func split(_ text: String) -> (String, String, String) {
        let isSpace: (Character) -> Bool = { $0 == " " || String($0) == lineBreak }
        let lead = String(text.prefix(while: isSpace))
        let rest = text.dropFirst(lead.count)
        let trail = String(rest.reversed().prefix(while: isSpace).reversed())
        return (lead, String(rest.dropLast(trail.count)), trail)
    }
}
