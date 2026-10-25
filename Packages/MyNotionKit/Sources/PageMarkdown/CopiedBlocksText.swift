import Foundation
import MarkdownExport
import NotesCore

/// Скопированные в MyNotion блоки — для других программ: Markdown простым текстом (чат, редактор кода) и HTML
/// (почта, Pages, браузер). Упоминание — название страницы, дата — словами, файл — именем.
public enum CopiedBlocksText {
    /// `blocks` — блоки потока без `containerId` и содержимое их таблиц и колонок; `pageTitle` — название
    /// страницы упоминания, `nil` — страницы нет.
    public static func markdown(for blocks: [Block], pageTitle: (UUID) -> String?) -> String {
        MarkdownBlockWriter().markdown(for: blocks, resolveLink: { id in
            pageTitle(id).map { PageLinkTarget(title: $0, path: nil) }
        }).trimmingCharacters(in: .newlines)
    }

    public static func html(for blocks: [Block], pageTitle: (UUID) -> String?) -> String {
        var flows: [UUID: [Block]] = [:]
        for block in blocks { if let containerId = block.containerId { flows[containerId, default: []].append(block) } }
        for key in flows.keys { flows[key]?.sort { $0.sortKey < $1.sortKey } }
        return withoutActuallyEscaping(pageTitle) { pageTitle in
            var writer = HTMLBlocksWriter(flow: { flows[$0] ?? [] }, pageTitle: pageTitle)
            return "<meta charset=\"utf-8\">" + writer.html(for: blocks.filter { $0.containerId == nil })
        }
    }
}

private struct HTMLBlocksWriter {
    let flow: (UUID) -> [Block]
    let pageTitle: (UUID) -> String?

    /// Открытые списки: тег и отступ пункта, у каждого открыт последний `<li>`.
    private var lists: [(tag: String, indent: Int)] = []
    private var output = ""

    init(flow: @escaping (UUID) -> [Block], pageTitle: @escaping (UUID) -> String?) {
        self.flow = flow
        self.pageTitle = pageTitle
    }

    mutating func html(for blocks: [Block]) -> String {
        for block in blocks { write(block) }
        closeLists(deeperThan: -1)
        return output
    }

    private mutating func write(_ block: Block) {
        let text = inline(block.text)
        switch block.kind {
        case .bulletItem, .numberedItem, .checkbox:
            let tag = block.kind == .numberedItem ? "ol" : "ul"
            openItem(tag, indent: block.indent)
            if block.kind == .checkbox { output += block.isChecked ? "<input type=\"checkbox\" checked disabled> " : "<input type=\"checkbox\" disabled> " }
            output += text
            return
        default:
            closeLists(deeperThan: -1)
        }
        switch block.kind {
        case .heading1: output += "<h1>\(text)</h1>"
        case .heading2: output += "<h2>\(text)</h2>"
        case .heading3: output += "<h3>\(text)</h3>"
        case .quote, .callout: output += "<blockquote><p>\(text)</p></blockquote>"
        case .divider: output += "<hr>"
        case .code:
            let language = block.props.language.map { " class=\"language-\(Self.escaped($0))\"" } ?? ""
            output += "<pre><code\(language)>\(Self.escaped(block.text.string))</code></pre>"
        case .equation: output += "<p>\(Self.escaped(block.text.string))</p>"
        case .table: output += table(block)
        case .columnList:
            var columns = HTMLBlocksWriter(flow: flow, pageTitle: pageTitle)
            for column in flow(block.id) { output += columns.html(for: flow(column.id)) }
        case .image, .file, .video, .bookmark:
            let name = block.props.attachment?.name ?? block.text.string
            if !name.isEmpty { output += "<p>\(Self.escaped(name))</p>" }
        case .pageLink, .database:
            if let id = block.linkedPageId, let title = pageTitle(id) { output += "<p>\(Self.escaped(title))</p>" }
        case .tableOfContents: break
        default: output += text.isEmpty ? "" : "<p>\(text)</p>"
        }
    }

    /// Пункт с отступом `indent`: глубже открытых — вложенный список внутри открытого `<li>`.
    private mutating func openItem(_ tag: String, indent: Int) {
        closeLists(deeperThan: indent)
        if let last = lists.last, last.indent == indent {
            if last.tag == tag {
                output += "</li><li>"
                return
            }
            output += "</li></\(last.tag)>"
            lists.removeLast()
        }
        output += "<\(tag)><li>"
        lists.append((tag, indent))
    }

    private mutating func closeLists(deeperThan indent: Int) {
        while let last = lists.last, last.indent > indent {
            output += "</li></\(last.tag)>"
            lists.removeLast()
        }
    }

    private func table(_ table: Block) -> String {
        let grid = TableGrid(table: table, flow: flow)
        guard grid.rowCount > 0, grid.columnCount > 0 else { return "" }
        let rows = (0..<grid.rowCount).map { row in
            let cellTag = row == 0 && grid.hasHeaderRow ? "th" : "td"
            let cells = (0..<grid.columnCount).map { "<\(cellTag)>\(inline(grid.text(row: row, column: $0)))</\(cellTag)>" }
            return "<tr>" + cells.joined() + "</tr>"
        }
        return "<table>" + rows.joined() + "</table>"
    }

    // MARK: Строка

    /// Текст блока с оформлением: каждый кусок одного вида — в своих тегах; упоминание — название, дата — словами.
    private func inline(_ text: InlineText) -> String {
        let units = Array(text.string.utf16)
        var boundaries: Set<Int> = [0, units.count]
        for run in text.runs {
            boundaries.insert(min(max(run.start, 0), units.count))
            boundaries.insert(min(max(run.start + run.length, 0), units.count))
        }
        let sorted = boundaries.sorted()
        return zip(sorted, sorted.dropFirst()).map { lower, upper in
            let styles = text.runs.filter { $0.start <= lower && $0.start + $0.length >= upper }.map(\.style)
            var piece = Self.escaped(String(decoding: units[lower..<upper], as: UTF16.self)).replacingOccurrences(of: "\n", with: "<br>")
            for style in styles {
                switch style {
                case .mention(let id): piece = Self.escaped(pageTitle(id) ?? InlineText.deletedPageTitle)
                case .date(let date):
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: date.timeZone) ?? .current
                    piece = Self.escaped(date.absoluteText(calendar: calendar))
                case .equation(let latex): piece = Self.escaped(latex)
                default: continue
                }
            }
            for style in styles {
                switch style {
                case .code: piece = "<code>\(piece)</code>"
                case .bold: piece = "<strong>\(piece)</strong>"
                case .italic: piece = "<em>\(piece)</em>"
                case .strikethrough: piece = "<s>\(piece)</s>"
                case .underline: piece = "<u>\(piece)</u>"
                default: continue
                }
            }
            if let url = styles.lazy.compactMap({ if case .link(let url) = $0 { url } else { nil } }).first {
                piece = "<a href=\"\(Self.escaped(url.absoluteString))\">\(piece)</a>"
            }
            return piece
        }.joined()
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
