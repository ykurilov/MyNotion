import Foundation
import NotesCore

/// Таблица и колонки из Markdown Notion и нашей выгрузки (contracts/markdown-and-notion.md).

/// Таблица Markdown — блок-таблица: столбцы, строки и ячейки внутри. У Notion первая строка — строка заголовков;
/// наша пометка `<!-- mynotion:table … -->` перед таблицей уточняет заголовки и ширины столбцов.
struct TableReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        var start = index
        let comment = Self.comment(lines[index])
        if comment != nil { start += 1 }
        guard start + 1 < lines.endIndex, lines[start].trimmingCharacters(in: .whitespaces).hasPrefix("|"),
              Self.isSeparator(lines[start + 1]) else { return nil }

        var rows = [Self.cells(lines[start].trimmingCharacters(in: .whitespaces))]
        var next = start + 2
        while next < lines.endIndex, lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            rows.append(Self.cells(lines[next].trimmingCharacters(in: .whitespaces)))
            next += 1
        }

        var props = BlockProps.defaults(for: .table)
        props.hasHeaderRow = comment?["header-row"].map { $0 == "true" } ?? true
        props.hasHeaderColumn = comment?["header-column"].map { $0 == "true" } ?? false
        let widths = comment?["widths"]?.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) } ?? []

        let columnCount = rows.map(\.count).max() ?? 1
        let columns = (0..<columnCount).map { position in
            var column = ParsedBlock(kind: .tableColumn, props: .defaults(for: .tableColumn))
            column.id = UUID()
            if position < widths.count, let width = widths[position] { column.props.width = width }
            return column
        }
        let rowBlocks = rows.map { cells in
            var row = ParsedBlock(kind: .tableRow)
            row.contained = cells.enumerated().compactMap { position, source -> ParsedBlock? in
                let parsed = NotionInlineParser.parse(source)
                guard !parsed.text.string.isEmpty else { return nil }
                var cellProps = BlockProps()
                cellProps.columnId = columns[position].id
                var cell = ParsedBlock(kind: .tableCell, text: parsed.text, props: cellProps)
                cell.mentions = parsed.pageMentions
                return cell
            }
            return row
        }
        let table = ParsedBlock(kind: .table, props: props, contained: columns + rowBlocks)
        return NotionBlockReading(blocks: [table], nextIndex: next)
    }

    /// Атрибуты пометки `<!-- mynotion:table header-row="…" header-column="…" widths="…" -->`.
    private static func comment(_ line: String) -> [String: String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("<!--"), trimmed.hasSuffix("-->") else { return nil }
        let body = trimmed.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        guard body == "mynotion:table" || body.hasPrefix("mynotion:table ") else { return nil }
        var attributes: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: #"([a-z-]+)="([^"]*)""#)
        for match in pattern.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let name = Range(match.range(at: 1), in: body), let value = Range(match.range(at: 2), in: body) else { continue }
            attributes[String(body[name])] = String(body[value])
        }
        return attributes
    }

    private static func isSeparator(_ line: String) -> Bool {
        line.range(of: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#, options: .regularExpression) != nil && line.contains("|")
    }

    /// Ячейки строки Markdown как есть: `\|` внутри ячейки — сама черта; оформление разбирает читатель ячейки.
    private static func cells(_ trimmed: String) -> [String] {
        var row = Substring(trimmed)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// `<div data-columns>` с `<div data-column data-width="…">` внутри — колонки нашей выгрузки.
struct ColumnsReader: NotionBlockReader {
    func read(_ lines: ArraySlice<String>, at index: Int) -> NotionBlockReading? {
        guard Self.opens(lines[index], attribute: "data-columns"),
              let (body, next) = StructuralMarkup.element("div", in: lines, at: index) else { return nil }
        var columns: [ParsedBlock] = []
        var simplifications: [NotionSimplification: Int] = [:]
        var position = body.startIndex
        let slice = body[...]
        while position < slice.endIndex {
            let line = slice[position]
            guard Self.opens(line, attribute: "data-column"),
                  let (inner, after) = StructuralMarkup.element("div", in: slice, at: position) else {
                position += 1
                continue
            }
            let parsed = NotionMarkdownParser.blocks(in: inner)
            simplifications.merge(parsed.simplifications, uniquingKeysWith: +)
            var column = ParsedBlock(kind: .column, contained: parsed.blocks)
            if let width = Self.attribute("data-width", in: line).flatMap(Double.init) { column.props.widthRatio = width }
            columns.append(column)
            position = after
        }
        guard !columns.isEmpty else { return nil }
        return NotionBlockReading(blocks: [ParsedBlock(kind: .columnList, contained: columns)], nextIndex: next,
                                  simplifications: simplifications)
    }

    /// `<div` с атрибутом `attribute` (без значения или со значением).
    private static func opens(_ line: String, attribute: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard StructuralMarkup.opens("div", trimmed), let end = trimmed.firstIndex(of: ">") else { return false }
        let tag = trimmed[..<end]
        return tag.split(separator: " ").dropFirst().contains { $0 == attribute || $0.hasPrefix(attribute + "=") }
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: name + #"="([^"]*)""#, options: .regularExpression) else { return nil }
        return String(line[range].dropFirst(name.count + 2).dropLast())
    }
}
