import NotesCore
import SwiftUI
import VisualStyle

/// Раздел «Избранное» (003, US2): избранные страницы в порядке ключа, у каждой подстраницы раскрываются стрелкой.
/// Строки тянутся внутри раздела — новое место запоминается ключом порядка страницы.
public enum FavoritesSection {
    public static let section = SidebarSection(id: .favorites, title: "Избранное")

    @MainActor
    public static func content(tree: PageTreeSnapshot, revision: Int, pageIds: [UUID], selectedPageId: UUID?,
                               liveTitle: String?, actions: PageTreeActions) -> SidebarSectionContent {
        SidebarSectionContent(section: section, content: AnyView(
            FavoritesSectionView(tree: tree, revision: revision, pageIds: pageIds, selectedPageId: selectedPageId,
                                 liveTitle: liveTitle, actions: actions)))
    }
}

private struct FavoritesSectionView: View {
    let tree: PageTreeSnapshot
    let revision: Int
    let pageIds: [UUID]
    let selectedPageId: UUID?
    let liveTitle: String?
    let actions: PageTreeActions
    /// Раскрытые ветки: по умолчанию подстраницы свёрнуты.
    @State private var expanded: Set<UUID> = []

    var body: some View {
        PageOutline(tree: tree, treeRevision: revision, collapsedPageIds: [], selectedPageId: selectedPageId,
                    liveTitle: liveTitle, actions: actions, kind: .favorites, rootPageIds: pageIds,
                    expandedPageIds: expanded, expandedPagesChanged: { expanded = $0 })
            .frame(height: CGFloat(min(visibleRowCount(of: pageIds), Metrics.Sidebar.favoritesMaxRows)) * Metrics.Sidebar.rowPitch)
    }

    /// Строки, которые видны: корни и подстраницы раскрытых веток.
    private func visibleRowCount(of ids: [UUID]) -> Int {
        ids.reduce(0) { count, id in
            guard tree.page(id) != nil else { return count }
            let inner = expanded.contains(id) ? visibleRowCount(of: tree.children(of: id).map(\.id)) : 0
            return count + 1 + inner
        }
    }
}
