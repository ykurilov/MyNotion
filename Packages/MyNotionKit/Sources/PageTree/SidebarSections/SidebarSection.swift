import NotesCore
import SwiftUI

/// Раздел боковой панели (contracts/pages-ui.md, «Боковая панель»): «Недавние», «Избранное», «Шаблоны», «Страницы».
/// Панель собирает разделы из описателей; каждая история добавляет свой файл в `SidebarSections/`.
public struct SidebarSection: Sendable, Identifiable {
    public let id: SidebarSectionID
    public let title: String

    public init(id: SidebarSectionID, title: String) {
        self.id = id
        self.title = title
    }

    /// Раздел дерева страниц — есть всегда.
    public static let pages = SidebarSection(id: .pages, title: "Страницы")

    /// Разделы сверху вниз, «Страницы» — всегда последним.
    public static func ordered(_ sections: [SidebarSection]) -> [SidebarSection] {
        var byId = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        byId[.pages] = byId[.pages] ?? .pages
        return SidebarSectionID.allCases.compactMap { byId[$0] }
    }
}

/// Раздел панели с содержимым: заголовок раздела рисует панель, строки — история (US2 «Недавние», «Избранное», US7 «Шаблоны»).
public struct SidebarSectionContent: Identifiable {
    public let section: SidebarSection
    public let content: AnyView
    public var id: SidebarSectionID { section.id }

    public init(section: SidebarSection, content: AnyView) {
        self.section = section
        self.content = content
    }
}
