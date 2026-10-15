import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Боковая панель: заголовок «Страницы», дерево и строка «Корзина» внизу.
public struct PageTreeSidebar: View {
    let tree: PageTreeSnapshot
    /// Меняется, когда дерево нужно перечитать.
    let treeRevision: Int
    let collapsedPageIds: Set<UUID>
    let selectedPageId: UUID?
    /// Название открытой страницы прямо во время набора.
    let liveTitle: String?
    let trashEntries: [Page]
    let actions: PageTreeActions
    let trashActions: TrashActions
    /// Место сверху под кнопками окна.
    let topInset: CGFloat

    @State private var trashPanel = TrashPanelController()

    public init(tree: PageTreeSnapshot, treeRevision: Int, collapsedPageIds: Set<UUID>, selectedPageId: UUID?,
                liveTitle: String?, trashEntries: [Page], actions: PageTreeActions, trashActions: TrashActions,
                topInset: CGFloat) {
        self.tree = tree
        self.treeRevision = treeRevision
        self.collapsedPageIds = collapsedPageIds
        self.selectedPageId = selectedPageId
        self.liveTitle = liveTitle
        self.trashEntries = trashEntries
        self.actions = actions
        self.trashActions = trashActions
        self.topInset = topInset
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("Страницы")
            PageOutline(tree: tree, treeRevision: treeRevision, collapsedPageIds: collapsedPageIds,
                        selectedPageId: selectedPageId, liveTitle: liveTitle, actions: actions)
            footerDivider
            trashRow
        }
        .padding(.horizontal, Metrics.Sidebar.panelInset)
        .padding(.top, topInset)
        .padding(.bottom, Metrics.Sidebar.footerBottomInset)
        .background(Color(nsColor: Palette.sidebarBackground))
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(Font(Typography.sidebarGroupHeader.font))
            .foregroundStyle(Color(nsColor: Palette.textSecondary))
            .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
            .frame(height: Metrics.Sidebar.rowHeight, alignment: .leading)
    }

    /// Линия цвета border между деревом и нижними строками: прокрученное дерево не сливается с «Корзиной».
    private var footerDivider: some View {
        Rectangle()
            .fill(Color(nsColor: Palette.border))
            .frame(height: 1)
            .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
            .padding(.vertical, Metrics.Sidebar.footerDividerSpacing)
    }

    /// «Корзина» — обычная строка панели: те же высота, поля, иконка 20×20 на вертикали иконок страниц.
    private var trashRow: some View {
        Button { trashPanel.toggle(entries: trashEntries, actions: trashActions) } label: {
            HStack(spacing: Metrics.Sidebar.rowIconSpacing) {
                Image(systemName: "trash")
                    .font(.system(size: Metrics.Sidebar.rowEmojiFontSize - 1, weight: .medium))
                    .foregroundStyle(Color(nsColor: Palette.sidebarText))
                    .frame(width: Metrics.Sidebar.rowIconSize, height: Metrics.Sidebar.rowIconSize)
                Text("Корзина")
                    .font(Font(Typography.sidebarRow.font))
                    .foregroundStyle(Color(nsColor: Palette.sidebarText))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
            .padding(.vertical, Metrics.Sidebar.rowVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.Sidebar.rowHeight, maxHeight: Metrics.Sidebar.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        .accessibilityIdentifier("sidebar-trash")
        .background(TrashPanelAnchor(controller: trashPanel))
        .onChange(of: trashEntries) { _, entries in trashPanel.update(entries: entries, actions: trashActions) }
        .onDisappear { trashPanel.close() }
    }
}

/// Строка «Корзина» для окна корзины: по ней окно находит своё место.
private struct TrashPanelAnchor: NSViewRepresentable {
    let controller: TrashPanelController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        controller.anchorView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        controller.anchorView = view
    }
}

/// Строка панели: при наведении — фон hoverBackground со скруглением, как у строк дерева.
struct SidebarRowButtonStyle: ButtonStyle {
    var cornerRadius = Metrics.Sidebar.rowCornerRadius

    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isHovered || configuration.isPressed ? Color(nsColor: Palette.hoverBackground) : .clear)
                )
                .onHover { isHovered = $0 }
        }
    }
}

/// `NSOutlineView` дерева внутри SwiftUI.
struct PageOutline: NSViewRepresentable {
    let tree: PageTreeSnapshot
    let treeRevision: Int
    let collapsedPageIds: Set<UUID>
    let selectedPageId: UUID?
    let liveTitle: String?
    let actions: PageTreeActions

    final class Coordinator {
        let dataSource: PageOutlineDataSource
        var shownRevision: Int?

        @MainActor init(actions: PageTreeActions) {
            dataSource = PageOutlineDataSource(actions: actions)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = PageOutlineView(frame: .zero)
        context.coordinator.dataSource.attach(to: outlineView)
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let dataSource = coordinator.dataSource
        dataSource.actions = actions
        if coordinator.shownRevision != treeRevision {
            coordinator.shownRevision = treeRevision
            dataSource.show(tree, collapsedPageIds: collapsedPageIds, selectedPageId: selectedPageId)
        } else {
            dataSource.select(selectedPageId)
        }
        dataSource.setLiveTitle(liveTitle, of: selectedPageId)
    }
}
