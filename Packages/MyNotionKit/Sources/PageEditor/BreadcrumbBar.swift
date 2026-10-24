import AppKit
import SwiftUI
import VisualStyle

/// Путь над страницей: предки нажимаются (рука и подсветка, как у кнопок панели), «…» открывает меню спрятанных,
/// текущая страница — просто текст. Нажатие открывает страницу переходом в текущей вкладке (с историей).
struct BreadcrumbBar: View {
    let ancestors: [BreadcrumbAncestor]
    let current: String
    let width: Double
    let onOpenPage: @MainActor (UUID) -> Void

    /// Подсветка выходит за текст на столько, не сдвигая сам путь.
    private static let hoverInset: CGFloat = 4

    var body: some View {
        let parts = BreadcrumbPath.parts(ancestors: ancestors, current: current, width: width, measure: BreadcrumbText.measure)
        HStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text(BreadcrumbText.styled(BreadcrumbText.separator)).fixedSize().padding(.horizontal, -Self.hoverInset) }
                switch part {
                case .page(let ancestor):
                    BreadcrumbButton(title: ancestor.title, identifier: "breadcrumb-ancestor") { onOpenPage(ancestor.pageId) }
                case .hidden(let hidden):
                    BreadcrumbMenu(hidden: hidden, onOpenPage: onOpenPage)
                case .current(let title):
                    Text(BreadcrumbText.styled(title))
                        .lineLimit(1)
                        .accessibilityIdentifier("page-breadcrumb")
                        // «/» перед текущей заходит на место поля подсветки соседней кнопки: возвращаем текст на место.
                        .padding(.leading, index > 0 ? Self.hoverInset : 0)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        // Первая часть-кнопка с полем подсветки: сам текст стоит там же, где стоял бы без неё.
        .padding(.leading, startsWithButton(parts) ? -Self.hoverInset : 0)
    }

    private func startsWithButton(_ parts: [BreadcrumbPath.Part]) -> Bool {
        if case .current = parts.first { false } else { true }
    }

    /// Подпись с подсветкой при наведении. Поля подсветки входят в размер кнопки (нажимаемая область и рамка
    /// для доступности совпадают); соседние «/» заходят на них, и путь стоит там же, где стоял текстом.
    fileprivate struct HoverLabel: View {
        let text: AttributedString
        let isHovered: Bool

        var body: some View {
            Text(text)
                .lineLimit(1)
                .padding(.horizontal, BreadcrumbBar.hoverInset)
                .frame(height: Metrics.Page.topBarButtonSize - 4)
                .background(RoundedRectangle(cornerRadius: Metrics.Window.toolbarButtonCornerRadius)
                    .fill(isHovered ? Color(nsColor: Palette.hoverBackground) : .clear))
                .contentShape(Rectangle())
        }
    }
}

private struct BreadcrumbButton: View {
    let title: String
    let identifier: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            BreadcrumbBar.HoverLabel(text: BreadcrumbText.styled(title), isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

private struct BreadcrumbMenu: View {
    let hidden: [BreadcrumbAncestor]
    let onOpenPage: @MainActor (UUID) -> Void
    @State private var isHovered = false

    var body: some View {
        Menu {
            ForEach(hidden) { ancestor in
                Button(ancestor.title) { onOpenPage(ancestor.pageId) }
            }
        } label: {
            BreadcrumbBar.HoverLabel(text: BreadcrumbText.styled(BreadcrumbText.ellipsis), isHovered: isHovered)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .accessibilityLabel("Скрытые страницы пути")
        .accessibilityIdentifier("breadcrumb-more")
    }
}
