import PageTree
import SwiftUI
import VisualStyle

/// Вкладка в полосе: название и иконка страницы; без страницы — «Недавние».
struct TabStripItem: Identifiable, Equatable {
    enum Icon: Equatable {
        case none
        case emoji(String)
        case recentPages
    }

    static let recentPagesTitle = "Недавние"

    let id: UUID
    let title: String
    let icon: Icon
    let isActive: Bool
}

/// Что умеет полоса: окно делает это через свою модель.
struct TabStripActions {
    var back: () -> Void
    var forward: () -> Void
    var activate: (Int) -> Void
    var close: (Int) -> Void
    var move: (Int, Int) -> Void
    var newTab: () -> Void
}

/// Полоса вкладок в строке светофора, как у Notion 7.39 для Mac (contracts/pages-ui.md, «Верхняя полоса окна»):
/// «‹ ›», вкладки с линиями между ними, «+». Активная — цветом страницы и без линии снизу; «×» — под мышью.
/// Вкладки тянут мышью — порядок меняется.
struct TabStripView: View {
    let items: [TabStripItem]
    let canGoBack: Bool
    let canGoForward: Bool
    /// Отступ слева: при спрятанной панели полоса начинается за шторкой.
    let leadingInset: CGFloat
    /// Галерея: «×» как под мышью.
    var previewHoveredTabId: UUID?
    let actions: TabStripActions

    @State private var hoveredTabId: UUID?
    @State private var dragged: (id: UUID, translation: CGFloat)?

    private typealias Tabs = Metrics.Tabs

    var body: some View {
        GeometryReader { proxy in
            let width = tabWidth(in: proxy.size.width)
            ZStack(alignment: .topLeading) {
                // Линия под полосой; активная вкладка закрывает её своим фоном.
                Rectangle()
                    .fill(Color(nsColor: Palette.tabSeparator))
                    .frame(height: Tabs.separatorWidth)
                    .offset(y: Tabs.stripHeight)
                HStack(spacing: 0) {
                    WindowDragArea().frame(width: leadingInset, height: Tabs.stripHeight)
                    navigation
                    separator
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        tab(item, at: index, width: width)
                    }
                    WindowToolbarButton(symbol: "plus", symbolSize: Tabs.plusSymbolSize, label: "Новая вкладка", action: actions.newTab)
                        .accessibilityIdentifier("tab-new")
                        .padding(.leading, Tabs.plusCenterFromTabsEnd - Metrics.Window.toolbarButtonSize / 2)
                        .frame(height: Tabs.stripHeight)
                    // Пустое место полосы тянет окно, как у Notion.
                    WindowDragArea().frame(maxWidth: .infinity, maxHeight: Tabs.stripHeight)
                }
            }
        }
        .frame(height: Metrics.Window.titleBarHeight)
        .clipped()
        .background(Color(nsColor: Palette.tabStripBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-strip")
    }

    private var navigation: some View {
        ZStack(alignment: .leading) {
            WindowToolbarButton(symbol: "chevron.left", symbolSize: Tabs.arrowSymbolSize, label: "Назад", isEnabled: canGoBack,
                                action: actions.back)
                .accessibilityIdentifier("tab-back")
                .offset(x: Tabs.backCenterX - Metrics.Window.toolbarButtonSize / 2)
            WindowToolbarButton(symbol: "chevron.right", symbolSize: Tabs.arrowSymbolSize, label: "Вперёд", isEnabled: canGoForward,
                                action: actions.forward)
                .accessibilityIdentifier("tab-forward")
                .offset(x: Tabs.forwardCenterX - Metrics.Window.toolbarButtonSize / 2)
        }
        .frame(width: Tabs.navigationWidth, height: Tabs.stripHeight, alignment: .leading)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: Palette.tabSeparator))
            .frame(width: Tabs.separatorWidth, height: Tabs.stripHeight)
    }

    private func tab(_ item: TabStripItem, at index: Int, width: CGFloat) -> some View {
        let isDragged = dragged?.id == item.id
        return HStack(spacing: 0) {
            let isHovered = (hoveredTabId ?? previewHoveredTabId) == item.id
            TabView(item: item, width: width, isHovered: isHovered)
                // Поверх вкладки: в строке светофора место под видом SwiftUI система считает «тянуть окно».
                .overlay(TabMouseArea(
                    onHover: { inside in
                        if inside { hoveredTabId = item.id } else if hoveredTabId == item.id { hoveredTabId = nil }
                    },
                    onClick: { actions.activate(index) },
                    onDrag: { dragged = (item.id, $0) },
                    onDragEnd: { translation in
                        dragged = nil
                        let step = width + Tabs.separatorWidth
                        let target = min(max(0, index + Int((translation / step).rounded())), items.count - 1)
                        if target != index { actions.move(index, target) }
                    }
                ))
                .overlay(alignment: .trailing) {
                    if isHovered {
                        CloseTabButton { actions.close(index) }
                            .padding(.trailing, Tabs.closeCenterFromTrailing - Tabs.closeButtonSize / 2)
                            .frame(height: Tabs.stripHeight)
                    }
                }
            separator
        }
        .offset(x: isDragged ? dragged?.translation ?? 0 : 0)
        .zIndex(isDragged ? 1 : 0)
    }

    /// Вкладки во всю ширину 199; не влезают — сжимаются поровну, но не уже `minimumTabWidth`.
    private func tabWidth(in stripWidth: CGFloat) -> CGFloat {
        let plusArea = Tabs.plusCenterFromTabsEnd + Metrics.Window.toolbarButtonSize
        let available = stripWidth - leadingInset - Tabs.navigationWidth - Tabs.separatorWidth - plusArea
        let fitting = available / CGFloat(max(items.count, 1)) - Tabs.separatorWidth
        return min(Tabs.tabWidth, max(Tabs.minimumTabWidth, fitting.rounded(.down)))
    }
}

/// Одна вкладка: иконка, название (у активной — «…», у остальных — затухание). Что влезает — `TabContentLayout`:
/// узкая вкладка с иконкой показывает одну иконку, место под «×» берётся только под мышью.
private struct TabView: View {
    let item: TabStripItem
    let width: CGFloat
    let isHovered: Bool

    private typealias Tabs = Metrics.Tabs

    var body: some View {
        let layout = TabContentLayout(width: width, hasIcon: item.icon != .none, isHovered: isHovered)
        HStack(spacing: Tabs.iconTitleGap) {
            icon
            if layout.showsTitle { title.frame(width: layout.titleWidth, alignment: .leading) }
        }
        .padding(.leading, layout.inset)
        .frame(width: width, height: item.isActive ? Tabs.stripHeight + Tabs.separatorWidth : Tabs.stripHeight, alignment: .leading)
        .clipped()
        .frame(height: Tabs.stripHeight, alignment: .top)
        .background(alignment: .top) {
            if item.isActive {
                Color(nsColor: Palette.pageBackground).frame(height: Tabs.stripHeight + Tabs.separatorWidth)
            }
        }
        .accessibilityElement(children: .contain)
        // Активная — своим идентификатором: признак «выбрана» доступность SwiftUI отдаёт ненадёжно.
        .accessibilityIdentifier(item.isActive ? "window-tab-active" : "window-tab")
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.isActive ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .none:
            EmptyView()
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: Tabs.iconSize - 2))
                .frame(width: Tabs.iconSize, height: Tabs.iconSize)
        case .recentPages:
            Image(systemName: "clock")
                .font(.system(size: Tabs.iconSize - 3))
                .foregroundStyle(titleColor)
                .frame(width: Tabs.iconSize, height: Tabs.iconSize)
        }
    }

    private var titleColor: Color {
        Color(nsColor: item.isActive ? Palette.textPrimary : Palette.tabInactiveTitle)
    }

    @ViewBuilder
    private var title: some View {
        let text = Text(item.title)
            .font(.system(size: Tabs.titleFontSize))
            .foregroundStyle(titleColor)
            .lineLimit(1)
        if item.isActive {
            text.truncationMode(.tail)
        } else {
            // Не влезло — конец затухает, как у Notion. Название во всю длину лежит поверх места и обрезается им.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: Tabs.titleFontSize * 1.5)
                .overlay(alignment: .leading) { text.fixedSize() }
                .clipped()
                .mask(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: Tabs.titleFadeWidth)
                    }
                }
        }
    }
}

/// «×» вкладки: значок 10 в квадрате 20, под мышью — фон.
private struct CloseTabButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: Metrics.Tabs.closeSymbolSize, weight: .medium))
                .foregroundStyle(Color(nsColor: Palette.tabClose))
                .frame(width: Metrics.Tabs.closeButtonSize, height: Metrics.Tabs.closeButtonSize)
                .background(RoundedRectangle(cornerRadius: 4).fill(isHovered ? Color(nsColor: Palette.hoverBackground) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Закрыть вкладку")
        .accessibilityLabel("Закрыть вкладку")
        .accessibilityIdentifier("tab-close")
    }
}

/// Мышь у вкладки — видом AppKit: в строке светофора жест перетаскивания SwiftUI двигал бы окно, а этот вид окно
/// не двигает. Щелчок — по отпусканию без сдвига; сдвиг больше 4 — перетаскивание вкладки.
private struct TabMouseArea: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onClick: () -> Void
    var onDrag: (CGFloat) -> Void
    var onDragEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> MouseView { MouseView() }

    func updateNSView(_ view: MouseView, context: Context) {
        view.handlers = self
    }

    final class MouseView: NSView {
        var handlers: TabMouseArea?
        private var start: NSPoint?
        private var isDragging = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { handlers?.onHover(true) }
        override func mouseExited(with event: NSEvent) { handlers?.onHover(false) }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let translation = event.locationInWindow.x - start.x
            if abs(translation) > 4 { isDragging = true }
            if isDragging { handlers?.onDrag(translation) }
        }

        override func mouseUp(with event: NSEvent) {
            guard let start else { return }
            self.start = nil
            if isDragging { handlers?.onDragEnd(event.locationInWindow.x - start.x) } else { handlers?.onClick() }
        }
    }
}

/// Пустое место строки светофора: тянет окно. Само окно за фон не тянется — иначе тянулись бы и вкладки.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
    }
}
