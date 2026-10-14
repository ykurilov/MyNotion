import Foundation

/// Блок страницы: абзац, заголовок, пункт списка, чекбокс или ссылка на подстраницу (data-model.md, «Block»).
public struct Block: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let pageId: UUID
    public var kind: BlockKind
    public var text: InlineText
    /// Вложенность списков и чекбоксов, 0…8; у заголовков всегда 0.
    public var indent: Int
    /// Только для чекбокса.
    public var isChecked: Bool
    /// Только для ссылки на подстраницу.
    public var linkedPageId: UUID?
    public var sortKey: FractionalSortKey
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
        self.fieldClocks = fieldClocks
        self.textBaseClock = textBaseClock
    }

    /// Синхронизируемые поля; у каждого своя метка часов.
    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        /// Тип, отступ и ссылка на подстраницу — одно поле.
        case kindAndIndent
        case text
        case isChecked
        case sortKey
        case deleted
    }

    func changedFields(comparedTo old: Block) -> Set<Field> {
        var fields: Set<Field> = []
        if kind != old.kind || indent != old.indent || linkedPageId != old.linkedPageId { fields.insert(.kindAndIndent) }
        if text != old.text { fields.insert(.text) }
        if isChecked != old.isChecked { fields.insert(.isChecked) }
        if sortKey != old.sortKey { fields.insert(.sortKey) }
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

    public var isHeading: Bool { self == .heading1 || self == .heading2 || self == .heading3 }
}

public struct BlockFieldClocks: Sendable, Hashable, Codable {
    public var kindAndIndent: HybridTimestamp?
    public var text: HybridTimestamp?
    public var isChecked: HybridTimestamp?
    public var sortKey: HybridTimestamp?
    public var deleted: HybridTimestamp?

    public init(kindAndIndent: HybridTimestamp? = nil, text: HybridTimestamp? = nil, isChecked: HybridTimestamp? = nil,
                sortKey: HybridTimestamp? = nil, deleted: HybridTimestamp? = nil) {
        self.kindAndIndent = kindAndIndent
        self.text = text
        self.isChecked = isChecked
        self.sortKey = sortKey
        self.deleted = deleted
    }

    mutating func stamp(_ fields: Set<Block.Field>, with timestamp: HybridTimestamp) {
        for field in fields {
            switch field {
            case .kindAndIndent: kindAndIndent = timestamp
            case .text: text = timestamp
            case .isChecked: isChecked = timestamp
            case .sortKey: sortKey = timestamp
            case .deleted: deleted = timestamp
            }
        }
    }
}

/// Страница вместе с её блоками по порядку.
public struct PageContent: Sendable, Hashable {
    public var page: Page
    public var blocks: [Block]
}
