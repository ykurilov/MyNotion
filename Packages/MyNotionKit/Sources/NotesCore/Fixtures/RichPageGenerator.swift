import Foundation

/// Блок «богатой» страницы: тип, текст, вложенность, цвет, свойства и блоки внутри контейнера (колонки, таблица).
public struct RichBlockSpec: Sendable, Hashable {
    public var id: UUID
    public var kind: BlockKind
    public var text: InlineText
    public var indent: Int
    public var color: BlockColor
    public var props: BlockProps
    /// Переключатель свёрнут на этом Mac (`block_view_state`).
    public var isCollapsed: Bool
    /// Блоки с `containerId` = этот блок: колонки `columnList`, блоки колонки, строки и столбцы таблицы, ячейки строки.
    public var contained: [RichBlockSpec]

    public init(_ kind: BlockKind, _ text: String = "", id: UUID = .timeOrdered(), indent: Int = 0, color: BlockColor? = nil,
                props: BlockProps? = nil, isCollapsed: Bool = false, contained: [RichBlockSpec] = []) {
        self.init(kind, text: InlineText(text), id: id, indent: indent, color: color, props: props, isCollapsed: isCollapsed,
                  contained: contained)
    }

    public init(_ kind: BlockKind, text: InlineText, id: UUID = .timeOrdered(), indent: Int = 0, color: BlockColor? = nil,
                props: BlockProps? = nil, isCollapsed: Bool = false, contained: [RichBlockSpec] = []) {
        self.id = id
        self.kind = kind
        self.text = text
        self.indent = indent
        self.color = color ?? .defaults(for: kind)
        self.props = props ?? .defaults(for: kind)
        self.isCollapsed = isCollapsed
        self.contained = contained
    }
}

/// Часть страницы от одного типа блока (описатель типа в `PageEditor/BlockKinds/`).
public struct RichPagePart: Sendable, Hashable {
    public var name: String
    public var blocks: [RichBlockSpec]

    public init(name: String, blocks: [RichBlockSpec]) {
        self.name = name
        self.blocks = blocks
    }
}

/// Эталонная «богатая» страница замеров (quickstart.md, research R16): 1 000 блоков потока страницы.
/// Каждый тип 002 добавляет свою часть (`parts`); остальное — текст 001 вперемешку, у каждого десятого блока цвет.
/// Части раскладываются по странице равномерно, между ними — заполнение.
public struct RichPageGenerator: Sendable {
    public static let title = "Замер: богатая страница"
    public static let blockCount = 1_000

    public let parts: [RichPagePart]

    public init(parts: [RichPagePart]) {
        self.parts = parts
    }

    /// Создать страницу, если её ещё нет; вернуть её id.
    @discardableResult
    public func ensure(in store: NotesStore) throws -> UUID {
        let outline = try store.pageOutline()
        if let existing = outline.first(where: { $0.title == Self.title && $0.trashedAt == nil }) { return existing.id }
        let lastRootKey = outline.filter { $0.parentId == nil }.map(\.sortKey).max()
        return try store.write { transaction in
            let now = Date()
            let page = Page(title: Self.title, icon: "🧪", sortKey: .between(lastRootKey, nil), createdAt: now, updatedAt: now)
            try transaction.insertPage(page)
            var key: FractionalSortKey?
            func insert(_ spec: RichBlockSpec, containerId: UUID?, after previous: inout FractionalSortKey?) throws {
                previous = .between(previous, nil)
                try transaction.insertBlock(Block(id: spec.id, pageId: page.id, kind: spec.kind, text: spec.text, indent: spec.indent,
                                                  isChecked: spec.kind == .checkbox && spec.indent % 2 == 1, sortKey: previous!,
                                                  containerId: containerId, color: spec.color, props: spec.props))
                if spec.isCollapsed {
                    try transaction.execute(sql: "INSERT OR REPLACE INTO block_view_state (blockId, isCollapsed) VALUES (?, 1)",
                                            arguments: [.text(spec.id.uuidString.lowercased())])
                }
                var innerKey: FractionalSortKey?
                for child in spec.contained { try insert(child, containerId: spec.id, after: &innerKey) }
            }
            for spec in layout() { try insert(spec, containerId: nil, after: &key) }
            return page.id
        }
    }

    /// Поток страницы: части по порядку, между ними заполнение до `blockCount`.
    func layout() -> [RichBlockSpec] {
        let partBlocks = parts.map(\.blocks)
        let fillerCount = max(0, Self.blockCount - partBlocks.reduce(0) { $0 + $1.count })
        let gap = fillerCount / (partBlocks.count + 1)
        var result: [RichBlockSpec] = []
        var fillerIndex = 0
        func fill(_ count: Int) {
            for _ in 0..<count {
                result.append(Self.filler(fillerIndex))
                fillerIndex += 1
            }
        }
        for blocks in partBlocks {
            fill(gap)
            result += blocks
        }
        fill(fillerCount - fillerIndex)
        return result
    }

    /// Текст 001 вперемешку; у каждого десятого блока цвет текста или фона.
    static func filler(_ index: Int) -> RichBlockSpec {
        let kind: BlockKind = switch index % 20 {
        case 0: .heading1
        case 10: .heading2
        case 1, 2, 3: .bulletItem
        case 11, 12: .numberedItem
        case 4, 14: .checkbox
        default: .paragraph
        }
        let text = "Блок \(index + 1): обычный текст страницы для замера, mixed with Latin words."
        let colors = NotionColor.allCases
        let color: BlockColor? = index % 10 == 5
            ? (index % 20 == 5 ? BlockColor(text: colors[index % colors.count]) : BlockColor(background: colors[index % colors.count]))
            : nil
        let indent = kind == .bulletItem || kind == .numberedItem ? (index % 20 == 2 || index % 20 == 12 ? 1 : 0) : 0
        return RichBlockSpec(kind, text, indent: indent, color: color)
    }
}
