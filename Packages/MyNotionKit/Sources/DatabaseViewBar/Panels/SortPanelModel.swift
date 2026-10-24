import Databases
import Foundation
import NotesCore

/// Окно сортировки без отрисовки (`notion-sort-popup.png`, `notion-sort-two-levels.png`): уровни, выбор свойства и
/// направления, новые списки сортировок.
public struct SortPanelModel: Sendable, Hashable {
    public struct Level: Sendable, Hashable {
        public let index: Int
        public let property: DatabaseProperty
        public let ascending: Bool
        public var directionTitle: String { FilterTexts.direction(ascending, kind: property.kind) }
    }

    public let sorts: [SortSpec]
    public let levels: [Level]

    public init(view: DatabaseView, catalog: DatabaseCatalog) {
        sorts = view.sortSpecs
        levels = sorts.enumerated().compactMap { index, sort in
            catalog.propertiesById[sort.propertyId].map { Level(index: index, property: $0, ascending: sort.ascending) }
        }
    }

    /// Направления меню уровня по типу его свойства.
    public static func directions(for kind: PropertyKind) -> [(ascending: Bool, title: String)] {
        [(true, FilterTexts.direction(true, kind: kind)), (false, FilterTexts.direction(false, kind: kind))]
    }

    /// Свойства меню уровня: его и те, по которым ещё нет уровня.
    public func propertyChoices(forLevel index: Int, catalog: DatabaseCatalog) -> [DatabaseProperty] {
        let used = Set(sorts.enumerated().filter { $0.offset != index }.map(\.element.propertyId))
        return PropertyChoices.forSort(catalog, excluding: used)
    }

    /// «+ Добавить сортировку»: свойства без уровня.
    public func addChoices(catalog: DatabaseCatalog, matching query: String = "") -> [DatabaseProperty] {
        PropertyChoices.forSort(catalog, excluding: Set(sorts.map(\.propertyId)), matching: query)
    }

    /// Уровень по другому свойству, направление сохраняется.
    public func replacingProperty(atLevel index: Int, with propertyId: UUID) -> [SortSpec] {
        var result = sorts
        guard result.indices.contains(index) else { return result }
        result[index].propertyId = propertyId
        return result
    }

    public func settingDirection(atLevel index: Int, ascending: Bool) -> [SortSpec] {
        var result = sorts
        guard result.indices.contains(index) else { return result }
        result[index].ascending = ascending
        return result
    }

    /// Куда встаёт уровень, отпущенный на место вставки `insertion` (0…число уровней) — индекс для `moveSort`.
    public static func moveDestination(from source: Int, insertion: Int) -> Int {
        insertion > source ? insertion - 1 : insertion
    }
}
