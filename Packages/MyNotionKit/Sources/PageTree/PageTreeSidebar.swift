import AppKit
import NotesCore
import SwiftUI
import VisualStyle

/// Боковая панель: верхняя строка в линию со светофором с «✎» справа, поле поиска, заголовок «Страницы», дерево
/// и «Корзина» внизу. Поле поиска — из модуля поиска: панель только отводит ему место.
public struct PageTreeSidebar<SearchField: View>: View {
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
    /// «✎» в верхней строке — то же, что ⌘N.
    let newPage: () -> Void
    let searchField: SearchField
    /// Значок синхронизации внизу (FR-022); `nil` — синхронизация выключена, строки нет.
    let syncBadge: SyncBadgeState?
    let openSyncSettings: () -> Void
    /// Разделы над «Страницами» (003): по порядку описателей `SidebarSection`.
    let sections: [SidebarSectionContent]
    /// Свёрнутые разделы (щелчок по заголовку); «Страницы» не сворачивается.
    let collapsedSections: Set<SidebarSectionID>
    let toggleSection: (SidebarSectionID) -> Void

    @State private var trashPanel = TrashPanelController()

    public init(tree: PageTreeSnapshot, treeRevision: Int, collapsedPageIds: Set<UUID>, selectedPageId: UUID?,
                liveTitle: String?, trashEntries: [Page], actions: PageTreeActions, trashActions: TrashActions,
                newPage: @escaping () -> Void, syncBadge: SyncBadgeState? = nil,
                openSyncSettings: @escaping () -> Void = {}, sections: [SidebarSectionContent] = [],
                collapsedSections: Set<SidebarSectionID> = [], toggleSection: @escaping (SidebarSectionID) -> Void = { _ in },
                @ViewBuilder searchField: () -> SearchField) {
        self.tree = tree
        self.treeRevision = treeRevision
        self.collapsedPageIds = collapsedPageIds
        self.selectedPageId = selectedPageId
        self.liveTitle = liveTitle
        self.trashEntries = trashEntries
        self.actions = actions
        self.trashActions = trashActions
        self.newPage = newPage
        self.syncBadge = syncBadge
        self.openSyncSettings = openSyncSettings
        self.sections = sections
        self.collapsedSections = collapsedSections
        self.toggleSection = toggleSection
        self.searchField = searchField()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topRow
            if SearchField.self != EmptyView.self {
                searchField
                    .frame(height: Metrics.SearchField.height)
                    .padding(.horizontal, Metrics.SearchField.extraHorizontalInset)
                    .padding(.top, Metrics.SearchField.topSpacing)
                    .padding(.bottom, Metrics.SearchField.bottomSpacing)
            }
            let shownSections = SidebarSection.ordered(sections.map(\.section)).filter { $0.id != .pages }
            ForEach(Array(shownSections.enumerated()), id: \.element.id) { index, section in
                SectionHeader(title: section.title, isCollapsed: collapsedSections.contains(section.id)) { toggleSection(section.id) }
                    .accessibilityIdentifier("sidebar-section-\(section.id.rawValue)")
                    .padding(.top, index == 0 ? 0 : Metrics.Sidebar.sectionTopSpacing)
                if !collapsedSections.contains(section.id) {
                    sections.first { $0.id == section.id }?.content
                }
            }
            groupHeader(SidebarSection.pages.title)
                .padding(.top, shownSections.isEmpty ? 0 : Metrics.Sidebar.sectionTopSpacing)
            PageOutline(tree: tree, treeRevision: treeRevision, collapsedPageIds: collapsedPageIds,
                        selectedPageId: selectedPageId, liveTitle: liveTitle, actions: actions)
            footerDivider
            trashRow
            if let syncBadge {
                SyncStatusBadge(state: syncBadge, openSettings: openSyncSettings)
            }
        }
        .padding(.horizontal, Metrics.Sidebar.panelInset)
        .padding(.bottom, Metrics.Sidebar.footerBottomInset)
        .background(Color(nsColor: Palette.sidebarBackground))
    }

    /// Строка светофора: слева место под кнопки окна и шторку (её рисует окно), справа «✎».
    private var topRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            WindowToolbarButton(symbol: "square.and.pencil", symbolSize: Metrics.Window.newPageSymbolSize,
                                label: "Новая страница", action: newPage)
                .accessibilityIdentifier("sidebar-new-page")
        }
        .frame(height: Metrics.Window.titleBarHeight)
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(Font(Typography.sidebarGroupHeader.font))
            .foregroundStyle(Color(nsColor: Palette.sidebarGroupHeader))
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

    /// «Корзина» — обычная строка панели: те же высота, поля, квадрат иконки и цвета, что у строк страниц.
    private var trashRow: some View {
        Button { trashPanel.toggle(entries: trashEntries, actions: trashActions) } label: {
            HStack(spacing: Metrics.Sidebar.rowIconSpacing) {
                Image(systemName: "trash")
                    .font(.system(size: Metrics.Sidebar.rowEmojiFontSize - 1, weight: .regular))
                    .foregroundStyle(Color(nsColor: Palette.sidebarIcon))
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

/// Заголовок сворачиваемого раздела: серый, как «Страницы»; под мышью справа от названия появляется стрелка.
private struct SectionHeader: View {
    let title: String
    let isCollapsed: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(title)
                    .font(Font(Typography.sidebarGroupHeader.font))
                    .foregroundStyle(Color(nsColor: Palette.sidebarGroupHeader))
                if isHovered {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: Metrics.Sidebar.sectionChevronSize, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Palette.sidebarGroupHeader))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
            .frame(height: Metrics.Sidebar.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(isCollapsed ? "Развернуть раздел" : "Свернуть раздел")
    }
}

extension PageTreeSidebar where SearchField == EmptyView {
    /// Панель без поля поиска.
    public init(tree: PageTreeSnapshot, treeRevision: Int, collapsedPageIds: Set<UUID>, selectedPageId: UUID?,
                liveTitle: String?, trashEntries: [Page], actions: PageTreeActions, trashActions: TrashActions,
                newPage: @escaping () -> Void) {
        self.init(tree: tree, treeRevision: treeRevision, collapsedPageIds: collapsedPageIds, selectedPageId: selectedPageId,
                  liveTitle: liveTitle, trashEntries: trashEntries, actions: actions, trashActions: trashActions,
                  newPage: newPage) { EmptyView() }
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

/// `NSOutlineView` дерева внутри SwiftUI. Тот же список показывает и разделы над деревом: «Избранное» и «Недавние».
struct PageOutline: NSViewRepresentable {
    let tree: PageTreeSnapshot
    /// Меняется, когда список нужно перечитать (у разделов — вместе с их данными).
    let treeRevision: Int
    let collapsedPageIds: Set<UUID>
    let selectedPageId: UUID?
    let liveTitle: String?
    let actions: PageTreeActions
    var kind: PageOutlineDataSource.Kind = .tree
    /// Разделы: страницы корня списка и раскрытые ветки.
    var rootPageIds: [UUID] = []
    var expandedPageIds: Set<UUID> = []
    var expandedPagesChanged: (Set<UUID>) -> Void = { _ in }

    final class Coordinator {
        let dataSource: PageOutlineDataSource
        var shownRevision: Int?

        @MainActor init(actions: PageTreeActions, kind: PageOutlineDataSource.Kind) {
            dataSource = PageOutlineDataSource(actions: actions, kind: kind)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions, kind: kind)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = PageOutlineView(frame: .zero)
        context.coordinator.dataSource.attach(to: outlineView)
        let scrollView = SidebarScrollView()
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
        dataSource.expandedPagesChanged = expandedPagesChanged
        if coordinator.shownRevision != treeRevision {
            coordinator.shownRevision = treeRevision
            dataSource.show(tree, collapsedPageIds: collapsedPageIds, selectedPageId: selectedPageId,
                            rootPageIds: rootPageIds, expandedPageIds: expandedPageIds)
        } else {
            dataSource.select(selectedPageId)
        }
        dataSource.setLiveTitle(liveTitle, of: selectedPageId)
    }
}

/// Прокрутка списков панели, как у Notion 7.39 (замер 21.10.2026): справа у всех разделов одно поле под полосу прокрутки
/// (строки «Недавних», «Избранного» и «Страниц» одной ширины — у Notion 239 при панели 270), полоса поверх этого поля;
/// прокрученный список гаснет сверху на 34 — строки не срезаются под заголовком. Снизу — без затухания, линия перед «Корзиной».
final class SidebarScrollView: NSScrollView {
    private let fade = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        super.scrollerStyle = .overlay
        wantsLayer = true
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(contentDidScroll), name: NSView.boundsDidChangeNotification,
                                               object: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    /// Полоса всегда поверх строк: с мышью без трекпада система ставила бы полосу сбоку, и дерево становилось бы уже разделов.
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    /// Сколько список прокручен от верха.
    var scrolledOffset: CGFloat { max(0, contentView.bounds.minY) }

    /// Затухание сверху: есть, только пока список прокручен.
    var isTopFaded: Bool { layer?.mask != nil }

    /// Видимая часть уже вида на поле справа; полоса прокрутки — в этом поле.
    override func tile() {
        super.tile()
        var clip = contentView.frame
        clip.size.width = max(0, bounds.width - Metrics.Sidebar.scrollGutter)
        contentView.frame = clip
    }

    override func layout() {
        super.layout()
        updateFade()
    }

    @objc private func contentDidScroll() { updateFade() }

    private func updateFade() {
        guard scrolledOffset > 0.5, bounds.height > 0 else {
            if layer?.mask != nil { layer?.mask = nil }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        // Слой не перевёрнут: верх вида — y = 1.
        let solid = min(1, Metrics.Sidebar.scrollTopFadeHeight / bounds.height)
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 1 - solid)
        if layer?.mask !== fade { layer?.mask = fade }
        CATransaction.commit()
    }
}
