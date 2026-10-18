import Foundation

/// Страница: узел дерева со своими блоками (data-model.md, «Page»).
public struct Page: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Может быть пустым; тогда показывается «Без названия».
    public var title: String
    /// Один эмодзи или пусто.
    public var icon: String?
    /// Пусто — корень дерева; не может указывать на себя или потомка.
    public var parentId: UUID?
    /// Порядок среди соседей.
    public var sortKey: FractionalSortKey
    /// Не пусто — страница в корзине вместе с потомками.
    public var trashedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var fieldClocks: PageFieldClocks

    public init(
        id: UUID = .timeOrdered(),
        title: String,
        icon: String? = nil,
        parentId: UUID? = nil,
        sortKey: FractionalSortKey,
        trashedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date,
        fieldClocks: PageFieldClocks = PageFieldClocks()
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.parentId = parentId
        self.sortKey = sortKey
        self.trashedAt = trashedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fieldClocks = fieldClocks
    }

    public static let untitledTitle = "Без названия"

    public var displayTitle: String { title.isEmpty ? Self.untitledTitle : title }

    /// В пути верхней полосы: иконка перед названием, как у Notion.
    public var pathTitle: String { [icon, displayTitle].compactMap { $0 }.joined(separator: " ") }

    /// Синхронизируемые поля; у каждого своя метка часов.
    public enum Field: String, Sendable, Hashable, CaseIterable, Codable {
        case title
        case icon
        /// Родитель и место среди соседей — одно поле.
        case placement
        case trashedAt
    }

    public func changedFields(comparedTo old: Page) -> Set<Field> {
        var fields: Set<Field> = []
        if title != old.title { fields.insert(.title) }
        if icon != old.icon { fields.insert(.icon) }
        if parentId != old.parentId || sortKey != old.sortKey { fields.insert(.placement) }
        if trashedAt != old.trashedAt { fields.insert(.trashedAt) }
        return fields
    }
}

public struct PageFieldClocks: Sendable, Hashable, Codable {
    public var title: HybridTimestamp?
    public var icon: HybridTimestamp?
    public var placement: HybridTimestamp?
    public var trashedAt: HybridTimestamp?

    public init(title: HybridTimestamp? = nil, icon: HybridTimestamp? = nil,
                placement: HybridTimestamp? = nil, trashedAt: HybridTimestamp? = nil) {
        self.title = title
        self.icon = icon
        self.placement = placement
        self.trashedAt = trashedAt
    }

    public mutating func stamp(_ fields: Set<Page.Field>, with timestamp: HybridTimestamp) {
        for field in fields {
            switch field {
            case .title: title = timestamp
            case .icon: icon = timestamp
            case .placement: placement = timestamp
            case .trashedAt: trashedAt = timestamp
            }
        }
    }
}
