import SwiftUI

/// Круглая кнопка в правом нижнем углу окна: открывает и закрывает панель ИИ-агента.
public struct AIChatToggleButton: View {
    @Bindable var controller: AIChatController
    @State private var isHovered = false

    public init(controller: AIChatController) {
        self.controller = controller
    }

    public var body: some View {
        Button { controller.isOpen.toggle() } label: {
            Image(systemName: controller.isOpen ? "xmark" : "sparkles")
                .font(.system(size: controller.isOpen ? 14 : 19, weight: .regular))
                .foregroundStyle(AIChatStyle.text)
                .frame(width: AIChatStyle.toggleSize, height: AIChatStyle.toggleSize)
                .background(Circle().fill(isHovered ? AIChatStyle.userBubble : AIChatStyle.popup))
                .overlay(Circle().stroke(AIChatStyle.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(controller.isOpen ? "Закрыть ИИ-агента" : "ИИ-агент")
        .accessibilityIdentifier("ai-chat-toggle")
    }
}

/// Панель ИИ-агента справа в окне: заголовок с прошлыми чатами, лента или пустое состояние, поле ввода.
public struct AIChatPanelView: View {
    @Bindable var controller: AIChatController

    public init(controller: AIChatController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if controller.entries.isEmpty && controller.reply == nil {
                AIChatEmptyState(controller: controller)
            } else {
                AIChatFeed(controller: controller)
            }
            AIChatComposer(controller: controller)
        }
        .frame(width: AIChatStyle.panelWidth)
        .frame(maxHeight: .infinity)
        .background(AIChatStyle.background)
        .overlay {
            // Щелчок мимо открытого списка закрывает его.
            if controller.popup != nil {
                Color.black.opacity(0.001).onTapGesture { controller.popup = nil }
            }
        }
        .overlay(alignment: .topLeading) {
            if controller.popup == .pastChats {
                AIChatPastChats(controller: controller)
                    .padding(.top, AIChatStyle.headerHeight - 4)
                    .padding(.leading, 8)
            }
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(AIChatStyle.divider).frame(width: 1)
        }
        .onExitCommand { controller.popup != nil ? (controller.popup = nil) : (controller.isOpen = false) }
        .accessibilityIdentifier("ai-chat-panel")
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button { controller.toggle(.pastChats) } label: {
                HStack(spacing: 4) {
                    Text(controller.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(AIChatStyle.secondary)
                }
                .foregroundStyle(AIChatStyle.text)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Прошлые чаты")
            .accessibilityIdentifier("ai-chat-history")
            Spacer(minLength: 8)
            AIChatIconButton(symbol: "square.and.pencil", help: "Новый чат") { controller.newChat() }
                .accessibilityIdentifier("ai-chat-new")
            AIChatIconButton(symbol: "xmark", help: "Закрыть") { controller.isOpen = false }
                .accessibilityIdentifier("ai-chat-close")
        }
        .padding(.horizontal, 8)
        .frame(height: AIChatStyle.headerHeight)
    }
}

/// Пустой чат: значок, вопрос и готовые просьбы про открытую страницу.
struct AIChatEmptyState: View {
    let controller: AIChatController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(AIChatStyle.text)
                .frame(width: 48, height: 48)
                .overlay(Circle().stroke(AIChatStyle.border, lineWidth: 1))
                .padding(.bottom, 10)
            Text("Чем помочь?")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AIChatStyle.text)
                .padding(.bottom, 12)
            ForEach(AIChatController.pageActions) { action in
                AIChatPopupRow(isSelected: false, action: { controller.run(action) }) {
                    Image(systemName: action.symbol).frame(width: 18).foregroundStyle(AIChatStyle.secondary)
                    Text(action.title)
                }
                .padding(.horizontal, -8)
                .accessibilityIdentifier("ai-chat-action-\(action.id)")
            }
        }
        .padding(.horizontal, AIChatStyle.horizontalPadding + 4)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
