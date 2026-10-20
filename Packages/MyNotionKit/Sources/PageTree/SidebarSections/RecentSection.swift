import NotesCore
import SwiftUI
import VisualStyle

/// Раздел «Недавние» (003, US2): пять последних страниц, где побывали, и строка «Показать все».
/// Список плоский: без подстраниц и перетаскивания.
public enum RecentSection {
    public static let section = SidebarSection(id: .recent, title: "Недавние")

    /// `showAll` — «Показать все» (список недавних открывает история вкладок); `nil` — строка есть, но молчит.
    @MainActor
    public static func content(tree: PageTreeSnapshot, revision: Int, pageIds: [UUID], selectedPageId: UUID?,
                               liveTitle: String?, actions: PageTreeActions, showAll: (() -> Void)? = nil) -> SidebarSectionContent {
        SidebarSectionContent(section: section, content: AnyView(
            RecentSectionView(tree: tree, revision: revision, pageIds: pageIds, selectedPageId: selectedPageId,
                              liveTitle: liveTitle, actions: actions, showAll: showAll)))
    }
}

private struct RecentSectionView: View {
    let tree: PageTreeSnapshot
    let revision: Int
    let pageIds: [UUID]
    let selectedPageId: UUID?
    let liveTitle: String?
    let actions: PageTreeActions
    let showAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageOutline(tree: tree, treeRevision: revision, collapsedPageIds: [], selectedPageId: selectedPageId,
                        liveTitle: liveTitle, actions: actions, kind: .recents, rootPageIds: pageIds)
                .frame(height: CGFloat(pageIds.filter { tree.page($0) != nil }.count) * Metrics.Sidebar.rowPitch)
            showAllRow
        }
    }

    /// «··· Показать все»: обычная строка панели с «⋯» вместо иконки.
    private var showAllRow: some View {
        Button { showAll?() } label: {
            HStack(spacing: Metrics.Sidebar.rowIconSpacing) {
                Image(systemName: "ellipsis")
                    .font(.system(size: Metrics.Sidebar.accessorySymbolSize, weight: .medium))
                    .foregroundStyle(Color(nsColor: Palette.sidebarGroupHeader))
                    .frame(width: Metrics.Sidebar.rowIconSize, height: Metrics.Sidebar.rowIconSize)
                Text("Показать все")
                    .font(Font(Typography.sidebarRow.font))
                    .foregroundStyle(Color(nsColor: Palette.sidebarGroupHeader))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.Sidebar.rowHeight, maxHeight: Metrics.Sidebar.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .accessibilityIdentifier("recents-show-all")
        .padding(.top, Metrics.Sidebar.rowPitch - Metrics.Sidebar.rowHeight)
    }
}
