import SwiftUI

/// Прошлые чаты под заголовком панели: поиск по названию, разделы по срокам, у каждого — дата и меню «Удалить».
struct AIChatPastChats: View {
    let controller: AIChatController
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private static let dateFormat = Date.FormatStyle().day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))

    var body: some View {
        let items = controller.chatList.map { PastChatGroups.Item(id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
        let groups = PastChatGroups.make(items, query: query)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(AIChatStyle.secondary)
                TextField("Найти чат", text: $query)
                    .textFieldStyle(.plain)
                    .font(AIChatStyle.bodyFont)
                    .focused($isSearchFocused)
                    .accessibilityIdentifier("ai-chat-history-search")
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(AIChatStyle.hover))
            .padding(.bottom, 4)
            if groups.isEmpty {
                Text(items.isEmpty ? "Чатов пока нет" : "Ничего не найдено")
                    .font(AIChatStyle.bodyFont)
                    .foregroundStyle(AIChatStyle.secondary)
                    .padding(8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            AIChatPopupHeader(title: group.title)
                            ForEach(group.items) { item in
                                AIChatPastChatRow(controller: controller, item: item, date: item.updatedAt.formatted(Self.dateFormat))
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 320)
        .aiChatPopupCard()
        .onAppear { isSearchFocused = true }
        .accessibilityIdentifier("ai-chat-history-list")
    }
}

/// Строка прошлого чата. Под мышью вместо даты — «…»: под строкой открывается меню с «Удалить».
private struct AIChatPastChatRow: View {
    let controller: AIChatController
    let item: PastChatGroups.Item
    let date: String
    @State private var isHovered = false

    private var isMenuOpen: Bool { controller.chatMenu == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AIChatPopupRow(isSelected: item.id == controller.chatID, action: { controller.openChat(item.id) }) {
                Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(AIChatStyle.secondary)
                Text(item.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(date)
                    .fixedSize()
                    .font(AIChatStyle.smallFont)
                    .foregroundStyle(AIChatStyle.secondary)
                    .opacity(isHovered || isMenuOpen ? 0 : 1)
            }
            .overlay(alignment: .trailing) {
                if isHovered || isMenuOpen {
                    Button { controller.toggleChatMenu(item.id) } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AIChatStyle.icon)
                            .frame(width: 24, height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(isMenuOpen ? AIChatStyle.hover : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 28)
                    .help("Действия с чатом")
                    .accessibilityLabel("Действия с чатом «\(item.title)»")
                    .accessibilityIdentifier("ai-chat-history-menu")
                }
            }
            if isMenuOpen {
                AIChatDeleteChatButton { controller.deleteChat(item.id) }
                    .padding(.leading, 22)
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Удалить на всех устройствах", role: .destructive) { controller.deleteChat(item.id) }
        }
    }
}

/// Пункт меню строки: удалить чат — с подписью, что это на всех устройствах.
private struct AIChatDeleteChatButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "trash").font(.system(size: 12)).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Удалить").font(AIChatStyle.bodyFont)
                    Text("Чат пропадёт на всех устройствах").font(AIChatStyle.smallFont).foregroundStyle(AIChatStyle.secondary)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(AIChatStyle.destructive)
            .padding(.horizontal, 8)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? AIChatStyle.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("ai-chat-history-delete")
    }
}
