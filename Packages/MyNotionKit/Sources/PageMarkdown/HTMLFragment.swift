import Foundation
import LinkPreview

/// Элемент HTML буфера обмена: имя в нижнем регистре, атрибуты с раскрытыми `&amp;` и содержимое по порядку.
final class HTMLElement {
    enum Content {
        case element(HTMLElement)
        case text(String)
    }

    let name: String
    let attributes: [String: String]
    fileprivate(set) var children: [Content] = []

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    var elements: [HTMLElement] {
        children.compactMap { if case .element(let element) = $0 { element } else { nil } }
    }

    /// Первый элемент с этим именем — сам или вглубь.
    func first(_ name: String) -> HTMLElement? {
        if self.name == name { return self }
        return elements.lazy.compactMap { $0.first(name) }.first
    }

    /// Внутри есть элемент с одним из этих имён.
    func contains(_ names: Set<String>) -> Bool {
        elements.contains { names.contains($0.name) || $0.contains(names) }
    }

    var classes: [Substring] { (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace) }

    /// Весь текст внутри, как написан; `<br>` — перевод строки.
    var rawText: String {
        children.map { content in
            switch content {
            case .text(let text): text
            case .element(let element): element.name == "br" ? "\n" : element.rawText
            }
        }.joined()
    }
}

/// HTML, который браузеры и редакторы кладут в буфер, → дерево `HTMLElement`. Не по стандарту, а с запасом прочности:
/// незакрытые `<p>`, `<li>`, `<td>` закрываются следующим таким же, лишние закрывающие теги пропускаются,
/// содержимое `<script>` и `<style>` не разбирается.
enum HTMLFragment {
    static func parse(_ html: String) -> HTMLElement {
        var parser = Parser(Array(html.unicodeScalars))
        return parser.run()
    }

    private static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                                                    "source", "track", "wbr"]
    private static let rawTextElements: Set<String> = ["script", "style", "textarea", "title", "xmp"]
    /// Начало такого блока закрывает открытый абзац.
    private static let closesParagraph: Set<String> = ["p", "div", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote",
                                                       "table", "hr", "section", "article", "header", "footer", "figure", "dl"]

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var position = 0
        let root = HTMLElement(name: "#root")
        var stack: [HTMLElement]
        var text = ""

        init(_ scalars: [Unicode.Scalar]) {
            self.scalars = scalars
            stack = [root]
        }

        mutating func run() -> HTMLElement {
            while position < scalars.count {
                let scalar = scalars[position]
                if scalar == "<", let next = peek(1) {
                    if next == "!" || next == "?" {
                        flushText()
                        skipDeclaration()
                        continue
                    }
                    if next == "/", let letter = peek(2), letter.properties.isAlphabetic {
                        flushText()
                        endTag()
                        continue
                    }
                    if next.properties.isAlphabetic {
                        flushText()
                        startTag()
                        continue
                    }
                }
                text.unicodeScalars.append(scalar)
                position += 1
            }
            flushText()
            return root
        }

        private func peek(_ offset: Int) -> Unicode.Scalar? {
            position + offset < scalars.count ? scalars[position + offset] : nil
        }

        private mutating func flushText() {
            guard !text.isEmpty else { return }
            stack[stack.count - 1].children.append(.text(HTMLMetadata.decodeEntities(text)))
            text = ""
        }

        /// `<!-- … -->`, `<!doctype>`, `<?xml?>`, условные комментарии Word `<![if …]>`.
        private mutating func skipDeclaration() {
            if peek(2) == "-", peek(3) == "-" {
                position += 4
                while position < scalars.count, !(scalars[position] == "-" && peek(1) == "-" && peek(2) == ">") { position += 1 }
                position = min(position + 3, scalars.count)
            } else {
                while position < scalars.count, scalars[position] != ">" { position += 1 }
                position = min(position + 1, scalars.count)
            }
        }

        private mutating func name() -> String {
            var name = ""
            while position < scalars.count, !Self.endsName(scalars[position]) {
                name.unicodeScalars.append(scalars[position])
                position += 1
            }
            return name.lowercased()
        }

        private static func endsName(_ scalar: Unicode.Scalar) -> Bool {
            scalar == ">" || scalar == "/" || scalar == "=" || scalar.properties.isWhitespace
        }

        private mutating func skipWhitespace() {
            while position < scalars.count, scalars[position].properties.isWhitespace { position += 1 }
        }

        private mutating func endTag() {
            position += 2
            let tag = name()
            while position < scalars.count, scalars[position] != ">" { position += 1 }
            position = min(position + 1, scalars.count)
            if let index = stack.lastIndex(where: { $0.name == tag }), index > 0 { stack.removeSubrange(index...) }
        }

        private mutating func startTag() {
            position += 1
            let tag = name()
            var attributes: [String: String] = [:]
            var selfClosing = false
            while position < scalars.count {
                skipWhitespace()
                guard position < scalars.count else { break }
                if scalars[position] == ">" { position += 1; break }
                if scalars[position] == "/" { selfClosing = true; position += 1; continue }
                let attribute = name()
                if attribute.isEmpty { position += 1; continue }
                skipWhitespace()
                var value = ""
                if position < scalars.count, scalars[position] == "=" {
                    position += 1
                    skipWhitespace()
                    value = attributeValue()
                }
                if attributes[attribute] == nil { attributes[attribute] = HTMLMetadata.decodeEntities(value) }
            }
            closeImplicitly(before: tag)
            let element = HTMLElement(name: tag, attributes: attributes)
            stack[stack.count - 1].children.append(.element(element))
            if HTMLFragment.rawTextElements.contains(tag) {
                element.children.append(.text(rawText(until: tag)))
            } else if !selfClosing, !HTMLFragment.voidElements.contains(tag) {
                stack.append(element)
            }
        }

        private mutating func attributeValue() -> String {
            guard position < scalars.count else { return "" }
            var value = ""
            let quote = scalars[position]
            if quote == "\"" || quote == "'" {
                position += 1
                while position < scalars.count, scalars[position] != quote {
                    value.unicodeScalars.append(scalars[position])
                    position += 1
                }
                position = min(position + 1, scalars.count)
            } else {
                while position < scalars.count, scalars[position] != ">", !scalars[position].properties.isWhitespace {
                    value.unicodeScalars.append(scalars[position])
                    position += 1
                }
            }
            return value
        }

        /// Содержимое `<script>`, `<style>` до закрывающего тега — как есть.
        private mutating func rawText(until tag: String) -> String {
            let closing = Array("</\(tag)".unicodeScalars)
            var content = ""
            while position < scalars.count {
                if scalars[position] == "<",
                   closing.indices.allSatisfy({ position + $0 < scalars.count
                       && String(scalars[position + $0]).lowercased() == String(closing[$0]) }) {
                    while position < scalars.count, scalars[position] != ">" { position += 1 }
                    position = min(position + 1, scalars.count)
                    break
                }
                content.unicodeScalars.append(scalars[position])
                position += 1
            }
            return content
        }

        /// Незакрытый `<li>`, `<td>`, `<tr>`, `<p>` закрывается, когда начинается следующий такой же или блок.
        private mutating func closeImplicitly(before tag: String) {
            switch tag {
            case "li": close("li", within: ["ul", "ol"])
            case "td", "th": close(["td", "th"], within: ["tr", "table"])
            case "tr": close(["tr"], within: ["table", "thead", "tbody", "tfoot"])
            case "dt", "dd": close(["dt", "dd"], within: ["dl"])
            default: break
            }
            if HTMLFragment.closesParagraph.contains(tag), stack.last?.name == "p" { stack.removeLast() }
        }

        private mutating func close(_ name: String, within boundaries: Set<String>) {
            close([name], within: boundaries)
        }

        private mutating func close(_ names: Set<String>, within boundaries: Set<String>) {
            guard let index = stack.lastIndex(where: { names.contains($0.name) || boundaries.contains($0.name) }),
                  index > 0, names.contains(stack[index].name) else { return }
            stack.removeSubrange(index...)
        }
    }
}
