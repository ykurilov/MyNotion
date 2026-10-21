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
    /// Пусто — обложки нет.
    public var cover: PageCover?
    /// Вид страницы: колонка во всю ширину и мелкий шрифт (research R2).
    public var isFullWidth: Bool
    public var isSmallText: Bool
    /// Место в разделе «Избранное» (дробный ключ); пусто — не в избранном. Страница в корзине его сохраняет.
    public var favorite: FractionalSortKey?
    /// Последнее открытие на любом Mac (research R4).
    public var visitedAt: Date?
    /// Шаблон живёт в корне и показывается в разделе «Шаблоны» (research R12).
    public var isTemplate: Bool
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
        cover: PageCover? = nil,
        isFullWidth: Bool = false,
        isSmallText: Bool = false,
        favorite: FractionalSortKey? = nil,
        visitedAt: Date? = nil,
        isTemplate: Bool = false,
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
        self.cover = cover
        self.isFullWidth = isFullWidth
        self.isSmallText = isSmallText
        self.favorite = favorite
        self.visitedAt = visitedAt
        self.isTemplate = isTemplate
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
        // 003
        case cover
        case isFullWidth
        case isSmallText
        case favorite
        case visitedAt
        case isTemplate

        /// Поля вида и порядка, а не содержимого: «изменено» страницы они не меняют и версий не порождают.
        public static let bookkeeping: Set<Field> = [.favorite, .visitedAt]
    }

    public func changedFields(comparedTo old: Page) -> Set<Field> {
        var fields: Set<Field> = []
        if title != old.title { fields.insert(.title) }
        if icon != old.icon { fields.insert(.icon) }
        if parentId != old.parentId || sortKey != old.sortKey { fields.insert(.placement) }
        if trashedAt != old.trashedAt { fields.insert(.trashedAt) }
        if cover != old.cover { fields.insert(.cover) }
        if isFullWidth != old.isFullWidth { fields.insert(.isFullWidth) }
        if isSmallText != old.isSmallText { fields.insert(.isSmallText) }
        if favorite != old.favorite { fields.insert(.favorite) }
        if visitedAt != old.visitedAt { fields.insert(.visitedAt) }
        if isTemplate != old.isTemplate { fields.insert(.isTemplate) }
        return fields
    }
}

public struct PageFieldClocks: Sendable, Hashable, Codable {
    public var title: HybridTimestamp?
    public var icon: HybridTimestamp?
    public var placement: HybridTimestamp?
    public var trashedAt: HybridTimestamp?
    public var cover: HybridTimestamp?
    public var isFullWidth: HybridTimestamp?
    public var isSmallText: HybridTimestamp?
    public var favorite: HybridTimestamp?
    public var visitedAt: HybridTimestamp?
    public var isTemplate: HybridTimestamp?

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
            case .cover: cover = timestamp
            case .isFullWidth: isFullWidth = timestamp
            case .isSmallText: isSmallText = timestamp
            case .favorite: favorite = timestamp
            case .visitedAt: visitedAt = timestamp
            case .isTemplate: isTemplate = timestamp
            }
        }
    }

    /// Все проставленные метки.
    public var all: [HybridTimestamp] {
        [title, icon, placement, trashedAt, cover, isFullWidth, isSmallText, favorite, visitedAt, isTemplate].compactMap { $0 }
    }

    public subscript(field: Page.Field) -> HybridTimestamp? {
        switch field {
        case .title: title
        case .icon: icon
        case .placement: placement
        case .trashedAt: trashedAt
        case .cover: cover
        case .isFullWidth: isFullWidth
        case .isSmallText: isSmallText
        case .favorite: favorite
        case .visitedAt: visitedAt
        case .isTemplate: isTemplate
        }
    }
}
