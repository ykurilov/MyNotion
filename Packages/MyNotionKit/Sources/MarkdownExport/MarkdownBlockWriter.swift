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

    /// `blocks` — блоки страницы всех потоков. Пишется поток страницы; колонки и таблицы пишут свои потоки сами
    /// (`BlockWriters/`). Блок, чьего контейнера нет, пишется в конце страницы.
    public func markdown(for blocks: [Block], resolveLink: (UUID) -> PageLinkTarget?) -> String {
        let ids = Set(blocks.map(\.id))
        var flows: [UUID: [Block]] = [:]
        var pageFlow: [Block] = []
        var orphans: [Block] = []
        for block in blocks {
            guard let containerId = block.containerId else { pageFlow.append(block); continue }
            if ids.contains(containerId) { flows[containerId, default: []].append(block) } else { orphans.append(block) }
        }
        return withoutActuallyEscaping(resolveLink) { resolveLink in
            func render(_ flow: [Block]) -> String {
                write(flow, context: MarkdownWriteContext(flow: { flows[$0] ?? [] }, render: render, resolveLink: resolveLink))
            }
            return render(pageFlow + orphans)
        }
    }

    private func write(_ blocks: [Block], context: MarkdownWriteContext) -> String {
        let resolveLink = context.resolveLink
        var lines: [String] = []
        var list = ListState()
        var previousWasListItem = false
        var position = 0
        while position < blocks.count {
            let block = blocks[position]
            position += 1
            if let writer = MarkdownBlockWriters.writer(for: block.kind) {
                var children: [String] = []
                if writer.writesChildren {
                    var end = position
                    while end < blocks.count, blocks[end].indent > block.indent { end += 1 }
                    let nested = blocks[position..<end].map { child -> Block in
                        var child = child
                        child.indent -= block.indent + 1
                        return child
                    }
                    let text = write(Array(nested), context: context)
                    children = text.isEmpty ? [] : Array(text.components(separatedBy: "\n").dropLast())
                    position = end
                }
                guard let content = writer.lines(for: block, children: children, context: context) else { continue }
                if !lines.isEmpty { lines.append("") }
                if let comment = ColorWriter.commentLine(for: block) { lines.append(comment) }
                lines.append(contentsOf: content)
                list.record(kind: block.kind, atIndent: 0, markerWidth: 0)
                previousWasListItem = false
                continue
            }
            let isListItem = Self.family(of: block.kind) != nil
            let indent = isListItem ? block.indent : 0
            let ordinal = list.nextOrdinal(atIndent: indent)
            guard let content = blockLines(block, ordinal: ordinal, nesting: list.nestingWidth(atIndent: indent), resolveLink: resolveLink)
            else { continue }
            let continuesList = isListItem && previousWasListItem && !list.startsNewList(kind: block.kind, atIndent: indent)
            if !lines.isEmpty, !continuesList { lines.append("") }
            if let comment = ColorWriter.commentLine(for: block) {
                lines.append(String(repeating: " ", count: content.first?.prefix { $0 == " " }.count ?? 0) + comment)
            }
            lines.append(contentsOf: content)
            list.record(kind: block.kind, atIndent: indent, markerWidth: Self.nestingStep(of: block, ordinal: ordinal))
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
    private func blockLines(_ block: Block, ordinal: Int, nesting: Int, resolveLink: (UUID) -> PageLinkTarget?) -> [String]? {
        switch block.kind {
        case .paragraph:
            return Self.splitLines(InlineMarkdown.render(block.text), firstPrefix: "", continuation: "")
        case .heading1, .heading2, .heading3:
            let level = block.kind == .heading1 ? 1 : block.kind == .heading2 ? 2 : 3
            // В заголовке Markdown строки одна: перенос заменяется пробелом той же длины, смещения оформления не сдвигаются.
            let flattened = InlineText(block.text.string.replacingOccurrences(of: "\n", with: " "), runs: block.text.runs)
            return ["\(String(repeating: "#", count: level)) \(InlineMarkdown.render(flattened))"]
        case .bulletItem, .checkbox, .numberedItem:
            return listLines(block, marker: Self.marker(for: block, ordinal: ordinal) ?? "", nesting: nesting)
        case .pageLink:
            guard let target = block.linkedPageId.flatMap(resolveLink) else { return nil }
            let title = escapedTitle(target.title)
            guard let path = target.path else { return [title] }
            return ["[\(title)](\(InlineMarkdown.encodedPath(path)))"]
        default:
            // Блок 002, у которого ещё нет своей записи: текст не теряется — абзацем.
            return Self.splitLines(InlineMarkdown.render(block.text), firstPrefix: "", continuation: "")
        }
    }

    /// Знак начала пункта. Его ширина задаёт отступ вложенных пунктов.
    private static func marker(for block: Block, ordinal: Int) -> String? {
        switch block.kind {
        case .bulletItem: "- "
        case .checkbox: block.isChecked ? "- [x] " : "- [ ] "
        case .numberedItem: "\(ordinal). "
        default: nil
        }
    }

    /// На сколько сдвинуты вложенные пункты. У чекбокса — ширина «- »: «[ ]» уже часть текста пункта, не знака.
    private static func nestingStep(of block: Block, ordinal: Int) -> Int {
        block.kind == .checkbox ? 2 : marker(for: block, ordinal: ordinal)?.count ?? 0
    }

    private func listLines(_ block: Block, marker: String, nesting: Int) -> [String] {
        let indentation = String(repeating: " ", count: nesting)
        return Self.splitLines(InlineMarkdown.render(block.text), firstPrefix: indentation + marker,
                               continuation: String(repeating: " ", count: nesting + marker.count))
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
        /// Ширина знака последнего пункта на каждом уровне: «- » — 2, «1. » — 3, «10. » — 4.
        private var markerWidths: [Int: Int] = [:]

        /// Отступ пункта: сумма ширин знаков предков (CommonMark вкладывает пункт в тот, под чьим текстом он начинается).
        /// Пропущенный уровень считается пунктом «- ».
        func nestingWidth(atIndent indent: Int) -> Int {
            (0..<indent).reduce(0) { $0 + (markerWidths[$1] ?? 2) }
        }

        func nextOrdinal(atIndent indent: Int) -> Int { (counts[indent] ?? 0) + 1 }

        /// Соседний пункт того же уровня другого вида (маркер вместо номера) — уже другой список.
        func startsNewList(kind: BlockKind, atIndent indent: Int) -> Bool {
            guard let family = MarkdownBlockWriter.family(of: kind), let previous = families[indent] else { return false }
            return previous != family
        }

        mutating func record(kind: BlockKind, atIndent indent: Int, markerWidth: Int) {
            guard let family = MarkdownBlockWriter.family(of: kind) else {
                counts = [:]
                families = [:]
                markerWidths = [:]
                return
            }
            counts = counts.filter { $0.key <= indent }
            families = families.filter { $0.key <= indent }
            markerWidths = markerWidths.filter { $0.key < indent }
            markerWidths[indent] = markerWidth
            counts[indent] = kind == .numberedItem ? (counts[indent] ?? 0) + 1 : nil
            families[indent] = family
        }
    }
}
