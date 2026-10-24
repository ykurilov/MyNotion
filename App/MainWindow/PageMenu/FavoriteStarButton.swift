import SwiftUI
import VisualStyle

/// «☆» в верхней полосе страницы, слева от «•••»: добавить в избранное или убрать. В избранном — закрашенная жёлтая «★».
struct FavoriteStarButton: View {
    let isFavorite: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    private var label: String { isFavorite ? "Убрать из избранного" : "Добавить в избранное" }

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color(nsColor: isFavorite ? Palette.favoriteStar : Palette.textSecondary))
                .frame(width: Metrics.Page.topBarButtonSize, height: Metrics.Page.topBarButtonSize)
                .background(RoundedRectangle(cornerRadius: Metrics.Window.toolbarButtonCornerRadius)
                    .fill(isHovered ? Color(nsColor: Palette.hoverBackground) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerStyle(.link)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("page-favorite-star")
    }
}
