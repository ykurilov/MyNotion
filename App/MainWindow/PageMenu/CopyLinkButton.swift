import PageEditor
import SwiftUI
import VisualStyle

/// Значок цепочки в верхней полосе страницы, слева от «☆», как у Notion: копирует ссылку `mynotion://page/<id>`.
/// Сразу после щелчка — галочка.
struct CopyLinkButton: View {
    let isCopied: Bool
    let copy: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: isCopied ? "checkmark" : "link")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .frame(width: Metrics.Page.topBarButtonSize, height: Metrics.Page.topBarButtonSize)
                .background(RoundedRectangle(cornerRadius: Metrics.Window.toolbarButtonCornerRadius)
                    .fill(isHovered ? Color(nsColor: Palette.hoverBackground) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .help(PageLinkCopy.title + " (⌘L)")
        .accessibilityLabel(PageLinkCopy.title)
        .accessibilityIdentifier("page-copy-link")
    }
}
