import Foundation
import NotesCore

/// Блок текста, который на iPhone правится (этап 1).
enum TextBlockKind: Hashable {
    case paragraph, heading1, heading2, heading3, bulletItem, numberedItem, checkbox, quote, toggle

    init?(_ kind: BlockKind) {
        switch kind {
        case .paragraph: self = .paragraph
        case .heading1: self = .heading1
        case .heading2: self = .heading2
        case .heading3: self = .heading3
        case .bulletItem: self = .bulletItem
        case .numberedItem: self = .numberedItem
        case .checkbox: self = .checkbox
        case .quote: self = .quote
        case .toggle: self = .toggle
        default: return nil
        }
    }
}

/// Как блок выглядит на экране iPhone.
enum BlockLook: Hashable {
    case text(TextBlockKind)
    case divider
    /// Ссылка на подстраницу: касание открывает её.
    case pageLink
    /// Тип, которого iPhone пока не показывает: неизменяемая карточка, данные блока не трогаются.
    case unsupported

    init(_ kind: BlockKind) {
        if let text = TextBlockKind(kind) {
            self = .text(text)
        } else if kind == .divider {
            self = .divider
        } else if kind == .pageLink {
            self = .pageLink
        } else {
            self = .unsupported
        }
    }

    var isEditableText: Bool {
        if case .text = self { true } else { false }
    }
}

/// Строка экрана: видимый блок потока страницы.
struct PageRow: Hashable {
    var block: Block
    /// Вложенность при показе (`BlockNesting`).
    var indent: Int
    /// Номер пункта нумерованного списка среди соседей того же уровня.
    var number: Int?
    var isCollapsed: Bool
    var hasChildren: Bool
    var look: BlockLook
}

enum PageRows {
    /// Видимые строки потока страницы: блоки под свёрнутым переключателем спрятаны.
    static func make(_ blocks: [Block], collapsed: Set<UUID>) -> [PageRow] {
        let indents = BlockNesting.displayIndents(blocks)
        var rows: [PageRow] = []
        rows.reserveCapacity(blocks.count)
        // Счёт пунктов по уровням: блок обнуляет счёт глубже себя, другой тип того же уровня — свой.
        var counters: [Int?] = []
        var hiddenDeeperThan: Int?
        for (index, block) in blocks.enumerated() {
            let indent = indents[index]
            if counters.count > indent + 1 { counters.removeSubrange((indent + 1)...) }
            while counters.count <= indent { counters.append(nil) }
            var number: Int?
            if block.kind == .numberedItem {
                number = (counters[indent] ?? 0) + 1
                counters[indent] = number
            } else {
                counters[indent] = nil
            }

            if let hidden = hiddenDeeperThan {
                if indent > hidden { continue }
                hiddenDeeperThan = nil
            }
            let hasChildren = index + 1 < blocks.count && indents[index + 1] > indent
            let isCollapsed = block.kind == .toggle && collapsed.contains(block.id)
            if isCollapsed { hiddenDeeperThan = indent }
            rows.append(PageRow(block: block, indent: indent, number: number, isCollapsed: isCollapsed, hasChildren: hasChildren,
                                look: BlockLook(block.kind)))
        }
        return rows
    }

    /// Последний блок под `index` вместе со всем, что вложено в него глубже (для свёрнутого переключателя).
    static func subtreeEnd(ofBlockAt index: Int, in blocks: [Block]) -> Int {
        let indents = BlockNesting.displayIndents(blocks)
        var end = index
        while end + 1 < blocks.count, indents[end + 1] > indents[index] { end += 1 }
        return end
    }
}

/// Подпись карточки блока, который iPhone пока не показывает: название типа и его текст, если есть.
struct UnsupportedBlockSummary: Hashable {
    var title: String
    var detail: String?

    init(title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }

    init(_ block: Block) {
        let text = block.text.string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        var detail = text.isEmpty ? (block.props.title ?? block.props.url?.absoluteString) : text
        if block.kind == .callout, let icon = block.props.icon { detail = [icon, detail].compactMap { $0 }.joined(separator: " ") }
        self.init(title: Self.title(of: block.kind), detail: detail?.isEmpty == true ? nil : detail)
    }

    private static func title(of kind: BlockKind) -> String {
        switch kind {
        case .callout: "Выноска"
        case .code: "Код"
        case .equation: "Формула"
        case .tableOfContents: "Оглавление"
        case .image: "Картинка"
        case .file: "Файл"
        case .video: "Видео"
        case .bookmark: "Закладка"
        case .table, .tableRow, .tableColumn, .tableCell: "Таблица"
        case .columnList, .column: "Колонки"
        case .database: "База данных"
        case .paragraph: "Текст"
        case .heading1, .heading2, .heading3: "Заголовок"
        case .bulletItem, .numberedItem: "Список"
        case .checkbox: "Задача"
        case .pageLink: "Страница"
        case .toggle: "Переключатель"
        case .quote: "Цитата"
        case .divider: "Разделитель"
        }
    }
}
