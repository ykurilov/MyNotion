import SwiftUI
import VisualStyle

/// Размеры и цвета панели ИИ-агента — из общей палитры приложения, светлой и тёмной.
enum AIChatStyle {
    static let panelWidth: CGFloat = 400
    static let headerHeight: CGFloat = 44
    static let horizontalPadding: CGFloat = 16
    static let toggleSize: CGFloat = 40
    static let popupCornerRadius: CGFloat = 10
    static let bodyFont = Font.system(size: 14)
    static let smallFont = Font.system(size: 12)
    static let stepFont = Font.system(size: 13)
    /// Межстрочный интервал ленты: 14 пт плюс 4 — строка около 21 пт, в полтора кегля, как в чате Notion AI.
    static let bodyLineSpacing: CGFloat = 4
    static let smallLineSpacing: CGFloat = 3
    /// Между абзацами и пунктами списка в ответе.
    static let blockSpacing: CGFloat = 8
    /// Между сообщениями, сводками шагов и ответами.
    static let messageSpacing: CGFloat = 16

    static let text = Color(nsColor: Palette.textPrimary)
    static let secondary = Color(nsColor: Palette.textSecondary)
    static let placeholder = Color(nsColor: Palette.placeholder)
    static let background = Color(nsColor: Palette.pageBackground)
    static let border = Color(nsColor: Palette.border)
    static let divider = Color(nsColor: Palette.sidebarEdge)
    static let hover = Color(nsColor: Palette.hoverBackground)
    static let popup = Color(nsColor: Palette.popupMenuBackground)
    static let userBubble = Color(nsColor: Palette.sidebarBackground)
    static let accent = Color(nsColor: Palette.primaryButtonFill)
    static let destructive = Color(nsColor: Palette.destructiveText)
    static let success = Color(nsColor: Palette.notionText(.green))
    static let icon = Color(nsColor: Palette.windowToolbarIcon)
}

/// Квадратная кнопка-значок заголовка панели.
struct AIChatIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(AIChatStyle.icon)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? AIChatStyle.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Строка всплывающего списка: подсветка под мышью, галочка у выбранного.
struct AIChatPopupRow<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label()
                Spacer(minLength: 0)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(AIChatStyle.text)
                    .opacity(isSelected ? 1 : 0)
            }
            .font(AIChatStyle.bodyFont)
            .foregroundStyle(AIChatStyle.text)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? AIChatStyle.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

extension View {
    /// Карточка всплывающего окна в стиле меню приложения.
    func aiChatPopupCard() -> some View {
        padding(6)
            .background(RoundedRectangle(cornerRadius: AIChatStyle.popupCornerRadius).fill(AIChatStyle.popup))
            .overlay(RoundedRectangle(cornerRadius: AIChatStyle.popupCornerRadius).stroke(AIChatStyle.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

/// Подпись раздела во всплывающем списке.
struct AIChatPopupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(AIChatStyle.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
