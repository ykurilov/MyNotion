import Databases
import DatabaseGrid
import Foundation
import NotesCore

/// «Видимость свойств» без отрисовки (`notion-view-property-visibility.png`): показанные по порядку колонок и скрытые,
/// поиск, место перетащенной колонки.
public struct PropertyVisibilityModel: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        public let property: DatabaseProperty
        /// «Название» не скрывается и не переставляется.
        public var isTitle: Bool { property.kind == .title }
        public var symbol: String { CellKind.for(property.kind).symbol }
    }

    /// Все показанные по порядку колонок (без поиска) — для мест перестановки.
    public let allShown: [DatabaseProperty]
    public let shown: [Item]
    public let hidden: [Item]

    public init(view: DatabaseView, catalog: DatabaseCatalog, query: String = "") {
        let visible = ViewQuery.visiblePropertyIds(of: view, catalog: catalog)
        let visibleSet = Set(visible)
        let query = query.trimmingCharacters(in: .whitespaces)
        let matches: (DatabaseProperty) -> Bool = {
            query.isEmpty || $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        allShown = visible.compactMap { catalog.propertiesById[$0] }
        shown = allShown.filter(matches).map(Item.init)
        hidden = catalog.properties.filter { !visibleSet.contains($0.id) && matches($0) }.map(Item.init)
    }

    /// Число показанных («Видимость свойств [N]»).
    public var shownCount: Int { allShown.count }

    /// Можно ли «Скрыть все» (есть что скрыть) и «Показать все».
    public var canHideAll: Bool { allShown.contains { $0.kind != .title } }
    public var canShowAll: Bool { !hidden.isEmpty }

    /// Колонку отпустили на место вставки `insertion` (0…число показанных) — индекс для `moveColumn` среди остальных
    /// видимых; `nil` — колонка не сдвинулась или это «Название».
    public func moveIndex(of propertyId: UUID, insertion: Int) -> Int? {
        guard let from = allShown.firstIndex(where: { $0.id == propertyId }), allShown[from].kind != .title else { return nil }
        let target = max(insertion > from ? insertion - 1 : insertion, 1)
        return target == from ? nil : target
    }
}
