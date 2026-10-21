import Databases
import Foundation
import NotesCore

/// Окно раскладки (`notion-layout-settings.png`, `notion-open-pages-in-options.png`, `notion-load-limit-options.png`).
public struct LayoutPanelModel: Sendable, Hashable {
    public let options: ViewLayoutOptions
    public let openMode: RowOpenMode
    /// «Предел загрузки» — только у встроенной: у полностраничной предела нет, прокрутка всей базы.
    public let showsLoadLimit: Bool

    public init(view: DatabaseView, isInline: Bool) {
        options = view.layout
        openMode = RowOpenMode(view: view)
        showsLoadLimit = isInline
    }

    public static let openModes: [(mode: RowOpenMode, title: String, caption: String)] = [
        (.sidePeek, "Сбоку", "Открывает страницы сбоку, вид позади остаётся рабочим"),
        (.centerPeek, "По центру", "Открывает страницу в окне по центру"),
        (.fullPage, "На всю страницу", "Открывает страницу целиком"),
    ]

    public var openModeTitle: String { Self.openModes.first { $0.mode == openMode }?.title ?? "Сбоку" }
    public static var loadLimits: [Int] { ViewLayoutOptions.loadLimits }
}

/// «Настройки вида» (`notion-view-settings-panel.png`): поле имени и пункты с серыми значениями.
public struct ViewSettingsModel: Sendable, Hashable {
    public enum Slot: String, Sendable, Hashable, CaseIterable {
        case layout, visibility, filter, sort, group, properties
    }

    public struct Row: Sendable, Hashable {
        public let slot: Slot
        public let title: String
        public let value: String?
        public let icon: String
    }

    public let name: String
    public let rows: [Row]

    public init(view: DatabaseView, catalog: DatabaseCatalog) {
        name = view.name
        let filters = FilterEditing.root(view.filterNode).children.count
        let sorts = view.sortSpecs.count
        let group = view.groupSettings.flatMap { catalog.propertiesById[$0.propertyId]?.name }
        rows = [
            Row(slot: .layout, title: "Раскладка", value: "Таблица", icon: "tablecells"),
            Row(slot: .visibility, title: "Видимость свойств", value: "\(PropertyVisibilityModel(view: view, catalog: catalog).shownCount)", icon: "eye"),
            Row(slot: .filter, title: "Фильтр", value: filters == 0 ? nil : FilterTexts.filters(filters), icon: "line.3.horizontal.decrease"),
            Row(slot: .sort, title: "Сортировка", value: sorts == 0 ? nil : FilterTexts.sorts(sorts), icon: "arrow.up.arrow.down"),
            Row(slot: .group, title: "Группировка", value: group, icon: "square.grid.3x1.below.line.grid.1x2"),
            Row(slot: .properties, title: "Свойства", value: nil, icon: "list.bullet"),
        ]
    }

    /// Подписи страниц панели («← Раскладка ×»).
    public static func pageTitle(_ slot: Slot) -> String {
        switch slot {
        case .layout: "Раскладка"
        case .visibility: "Видимость свойств"
        case .filter: "Фильтр"
        case .sort: "Сортировка"
        case .group: "Группировка"
        case .properties: "Свойства"
        }
    }
}
