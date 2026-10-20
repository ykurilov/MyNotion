import NotesCore
import SwiftUI
import VisualStyle

/// Страница вкладки ушла в корзину — здесь или на другом Mac (spec, крайние случаи): вкладка не закрывается сама,
/// а показывает полосу «Страница в корзине» с «Вернуть», как Notion, и название страницы.
struct TrashedPageView: View {
    let page: Page
    let restore: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Страница в корзине")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white)
                Button("Вернуть", action: restore)
                    .buttonStyle(TrashedPageButtonStyle())
                    .accessibilityIdentifier("trashed-page-restore")
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color(nsColor: Palette.destructiveButtonFill))
            HStack(spacing: 12) {
                if let icon = page.icon { Text(icon).font(.system(size: 36)) }
                Text(page.title.isEmpty ? Page.untitledTitle : page.title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
                    .lineLimit(2)
            }
            .frame(maxWidth: Metrics.Page.columnWidth, alignment: .leading)
            .padding(.top, 80)
            .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: Palette.pageBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trashed-page")
    }
}

/// Кнопка на красной полосе: белая рамка, белый текст.
private struct TrashedPageButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.8)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
