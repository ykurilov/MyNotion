import Foundation
import NotesCore

/// Куда ведёт блок-ссылка на подстраницу: название и путь файла относительно страницы, где стоит ссылка.
public struct PageLinkTarget: Sendable, Hashable {
    public var title: String
    /// Путь с `/`, как есть: пробелы и скобки кодируются при записи. Пути нет — страницы нет в выгрузке
    /// (она в корзине): в Markdown остаётся только название.
    public var path: String?

    public init(title: String, path: String?) {
        self.title = title
        self.path = path
    }
}

/// Блоки страницы в Markdown по таблице contracts/files-import-export.md. Ничего не знает о папках и базе:
/// на вход — блоки и способ найти файл подстраницы. Обратный разбор (импорт из Notion) строится по той же таблице.
public struct MarkdownBlockWriter: Sendable {
    public init() {}

    public func markdown(for blocks: [Block], resolveLink: (UUID) -> PageLinkTarget?) -> String {
        var lines: [String] = []
        var list = ListState()
        var previousWasListItem = false
        for block in blocks {
            let isListItem = Self.family(of: block.kind) != nil
            let indent = isListItem ? block.indent : 0
            guard let content = blockLines(block, ordinal: list.nextOrdinal(atIndent: indent), resolveLink: resolveLink) else { continue }
            let continuesList = isListItem && previousWasListItem && !list.startsNewList(kind: block.kind, atIndent: indent)
            if !lines.isEmpty, !continuesList { lines.append("") }
            lines.append(contentsOf: content)
            list.record(kind: block.kind, atIndent: indent)
            previousWasListItem = isListItem
        }
        while lines.last == "" { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// Название страницы в первой строке файла: знаки Markdown экранированы, перенос строки — пробел.
    func escapedTitle(_ title: String) -> String {
        let units = Array(title.replacingOccurrences(of: "\n", with: " ").utf16)
        return InlineMarkdown.escape(units, range: 0..<units.count)
    }

    // MARK: Блоки

    /// Строки блока без разделяющих пустых строк. `nil` — блок ничего не пишет; пустой массив — пустой абзац.
    private func blockLines(_ block: Block, ordinal: Int, resolveLink: (UUID) -> PageLinkTarget?) -> [String]? {
        switch block.kind {
        case .paragraph:
            return Self.splitLines(InlineMarkdown.render(block.text), firstPrefix: "", continuation: "")
        case .heading1, .heading2, .heading3:
            let level = block.kind == .heading1 ? 1 : block.kind == .heading2 ? 2 : 3
            // В заголовке Markdown строки одна: перенос заменяется пробелом той же длины, смещения оформления не сдвигаются.
            let flattened = InlineText(block.text.string.replacingOccurrences(of: "\n", with: " "), runs: block.text.runs)
            return ["\(String(repeating: "#", count: level)) \(InlineMarkdown.render(flattened))"]
        case .bulletItem:
            return listLines(block, marker: "- ")
        case .checkbox:
            return listLines(block, marker: block.isChecked ? "- [x] " : "- [ ] ")
        case .numberedItem:
            return listLines(block, marker: "\(ordinal). ")
        case .pageLink:
            guard let target = block.linkedPageId.flatMap(resolveLink) else { return nil }
            let title = escapedTitle(target.title)
            guard let path = target.path else { return [title] }
            return ["[\(title)](\(InlineMarkdown.encodedPath(path)))"]
        }
    }

    private func listLines(_ block: Block, marker: String) -> [String] {
        let nesting = String(repeating: " ", count: block.indent * 2)
        return Self.splitLines(InlineMarkdown.render(block.text), firstPrefix: nesting + marker,
                               continuation: String(repeating: " ", count: nesting.count + marker.count))
    }

    /// Перенос строки внутри блока — два пробела в конце строки; следующая строка начинается с отступа текста.
    private static func splitLines(_ text: String, firstPrefix: String, continuation: String) -> [String] {
        guard !text.isEmpty || !firstPrefix.isEmpty else { return [] }
        let parts = text.components(separatedBy: "\n")
        return parts.enumerated().map { index, part in
            (index == 0 ? firstPrefix : continuation) + part + (index < parts.count - 1 ? "  " : "")
        }
    }

    // MARK: Списки

    private enum ListFamily { case dashed, numbered }

    private static func family(of kind: BlockKind) -> ListFamily? {
        switch kind {
        case .bulletItem, .checkbox: .dashed
        case .numberedItem: .numbered
        default: nil
        }
    }

    /// Нумерация и границы списков так же, как в редакторе: считаются пункты одного уровня подряд,
    /// вложенные глубже счёт не прерывают.
    private struct ListState {
        private var counts: [Int: Int] = [:]
        private var families: [Int: ListFamily] = [:]

        func nextOrdinal(atIndent indent: Int) -> Int { (counts[indent] ?? 0) + 1 }

        /// Соседний пункт того же уровня другого вида (маркер вместо номера) — уже другой список.
        func startsNewList(kind: BlockKind, atIndent indent: Int) -> Bool {
            guard let family = MarkdownBlockWriter.family(of: kind), let previous = families[indent] else { return false }
            return previous != family
        }

        mutating func record(kind: BlockKind, atIndent indent: Int) {
            guard let family = MarkdownBlockWriter.family(of: kind) else {
                counts = [:]
                families = [:]
                return
            }
            counts = counts.filter { $0.key <= indent }
            families = families.filter { $0.key <= indent }
            counts[indent] = kind == .numberedItem ? (counts[indent] ?? 0) + 1 : nil
            families[indent] = family
        }
    }
}
