import Foundation

/// Блок страницы (data-model.md, «Block»): абзац, заголовок, пункт списка, чекбокс, ссылка на подстраницу и блоки 002 —
/// переключатель, цитата, выноска, код, вложения, таблицы, колонки.
public struct Block: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let pageId: UUID
    public var kind: BlockKind
    public var text: InlineText
    /// Вложенность внутри потока, 0…8; допустимая глубина при показе — `BlockNesting`.
    public var indent: Int
    /// Только для чекбокса.
    public var isChecked: Bool
    /// Только для ссылки на подстраницу.
    public var linkedPageId: UUID?
    /// Порядок в потоке.
    public var sortKey: FractionalSortKey
    /// Контейнер вне текста страницы: колонка, `columnList`, таблица или строка таблицы; `nil` — поток страницы.
    /// Вместе с `sortKey` — одно синхронизируемое поле `placement`.
    public var containerId: UUID?
    /// Цвет всего блока (FR-112).
    public var color: BlockColor
    /// Свойства по типу блока.
    public var props: BlockProps
    public var fieldClocks: BlockFieldClocks
    /// Версия текста, от которой началась правка; основа выявления конфликта (research R8).
    public var textBaseClock: HybridTimestamp?

    public static let indentRange = 0...8

    public init(
        id: UUID = .timeOrdered(),
        pageId: UUID,
        kind: BlockKind = .paragraph,
        text: InlineText = .empty,
        indent: Int = 0,
        isChecked: Bool = false,
        linkedPageId: UUID? = nil,
        sortKey: FractionalSortKey,
        containerId: UUID? = nil,
        color: BlockColor = .none,
        props: BlockProps = .empty,
        fieldClocks: BlockFieldClocks = BlockFieldClocks(),
        textBaseClock: HybridTimestamp? = nil
    ) {
        self.id = id
        self.pageId = pageId
        self.kind = kind
        self.text = text
        self.indent = indent
        self.isChecked = isChecked
        self.linkedPageId = linkedPageId
        self.sortKey = sortKey
        self.containerId = containerId
        self.color = color
        self.props = props
        self.fieldClocks = fieldClocks
        self.textBaseClock = textBaseClock
    }

    /// Синхронизируемые поля; у каждого своя метка часов.
    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        /// Тип, отступ и ссылка на подстраницу — одно поле.
        case kindAndIndent
        case text
        case isChecked
        /// Контейнер и порядок — одной меткой: перенос между колонками не рвётся на два поля.
        case placement
        case color
        case props
        case deleted
    }

    public func changedFields(comparedTo old: Block) -> Set<Field> {
        var fields: Set<Field> = []
        if kind != old.kind || indent != old.indent || linkedPageId != old.linkedPageId { fields.insert(.kindAndIndent) }
        if text != old.text { fields.insert(.text) }
        if isChecked != old.isChecked { fields.insert(.isChecked) }
        if sortKey != old.sortKey || containerId != old.containerId { fields.insert(.placement) }
        if color != old.color { fields.insert(.color) }
        if props != old.props { fields.insert(.props) }
        return fields
    }
}

public enum BlockKind: String, Sendable, Hashable, CaseIterable, Codable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bulletItem
    case numberedItem
    case checkbox
    case pageLink
    // 002
    case toggle
    case quote
    case callout
    case divider
    case code
    case equation
    case tableOfContents
    case image
    case file
    case video
    case bookmark
    case table
    case tableRow
    case tableColumn
    case tableCell
    case columnList
    case column

    public var isHeading: Bool { self == .heading1 || self == .heading2 || self == .heading3 }

    /// Под блоком можно вложить следующий на уровень глубже (research R1).
    public var canHaveChildren: Bool {
        switch self {
        case .bulletItem, .numberedItem, .checkbox, .toggle, .callout, .quote: true
        default: false
        }
    }

    /// Внутрь можно вложить и заголовок.
    public var allowsHeadingChildren: Bool { self == .toggle || self == .callout || self == .quote }

    /// Контейнер вне текста страницы: у его блоков `containerId` — id контейнера (research R3).
    public var isContainer: Bool {
        switch self {
        case .columnList, .column, .table, .tableRow: true
        default: false
        }
    }

    /// Абзац на странице — один знак-вложение со своим видом (research R2). Код — тоже: у него свой встроенный редактор,
    /// где строка кода — свой абзац (research R5, решение после пробы R16).
    public var rendersAsAttachment: Bool {
        switch self {
        case .divider, .code, .equation, .tableOfContents, .image, .file, .video, .bookmark, .table, .columnList: true
        default: false
        }
    }
}

public struct BlockFieldClocks: Sendable, Hashable, Codable {
    public var kindAndIndent: HybridTimestamp?
    public var text: HybridTimestamp?
    public var isChecked: HybridTimestamp?
    public var placement: HybridTimestamp?
    public var color: HybridTimestamp?
    public var props: HybridTimestamp?
    public var deleted: HybridTimestamp?

    public init(kindAndIndent: HybridTimestamp? = nil, text: HybridTimestamp? = nil, isChecked: HybridTimestamp? = nil,
                placement: HybridTimestamp? = nil, color: HybridTimestamp? = nil, props: HybridTimestamp? = nil,
                deleted: HybridTimestamp? = nil) {
        self.kindAndIndent = kindAndIndent
        self.text = text
        self.isChecked = isChecked
        self.placement = placement
        self.color = color
        self.props = props
        self.deleted = deleted
    }

    /// Все проставленные метки.
    public var all: [HybridTimestamp] {
        [kindAndIndent, text, isChecked, placement, color, props, deleted].compactMap { $0 }
    }

    public mutating func stamp(_ fields: Set<Block.Field>, with timestamp: HybridTimestamp) {
        for field in fields {
            switch field {
            case .kindAndIndent: kindAndIndent = timestamp
            case .text: text = timestamp
            case .isChecked: isChecked = timestamp
            case .placement: placement = timestamp
            case .color: color = timestamp
            case .props: props = timestamp
            case .deleted: deleted = timestamp
            }
        }
    }
}

/// Глубина блоков при показе (data-model.md, «Block»): «Глубина ≤ глубина соседа сверху + 1, если сосед — пункт, чекбокс,
/// переключатель, выноска или цитата; иначе 0» — под остальными блоками прибавляется 0, блок встаёт вровень с соседом.
/// «Заголовок глубже 0 — только внутри переключателя, выноски или цитаты». Записанная глубина не меняется:
/// больше допустимого (например, после слияния правок двух Mac) только урезается при показе.
public enum BlockNesting {
    public static func displayIndents(_ blocks: [Block]) -> [Int] {
        var indents: [Int] = []
        indents.reserveCapacity(blocks.count)
        // Типы предков текущего блока по уровням: ancestors[k] — ближайший блок выше на глубине k.
        var ancestors: [BlockKind] = []
        for (index, block) in blocks.enumerated() {
            var limit = 0
            if index > 0 {
                limit = indents[index - 1] + (blocks[index - 1].kind.canHaveChildren ? 1 : 0)
            }
            var indent = min(max(block.indent, Block.indentRange.lowerBound), min(limit, Block.indentRange.upperBound))
            if block.kind.isHeading {
                while indent > 0, !ancestors[indent - 1].allowsHeadingChildren { indent -= 1 }
            }
            ancestors.removeSubrange(min(indent, ancestors.count)...)
            ancestors.append(block.kind)
            indents.append(indent)
        }
        return indents
    }
}

/// Страница вместе с её блоками по порядку: блоки всех потоков, в каждом — по `sortKey`.
public struct PageContent: Sendable, Hashable {
    public var page: Page
    public var blocks: [Block]
    /// Контейнеры страницы, лежащие пометкой «удалён», и их собственный контейнер: по ним блок, чей контейнер удалён,
    /// находит, за каким `columnList` или `table` его показать (data-model.md, «Сироты после слияния»).
    public var removedContainers: [UUID: UUID?]

    public init(page: Page, blocks: [Block], removedContainers: [UUID: UUID?] = [:]) {
        self.page = page
        self.blocks = blocks
        self.removedContainers = removedContainers
    }
}
