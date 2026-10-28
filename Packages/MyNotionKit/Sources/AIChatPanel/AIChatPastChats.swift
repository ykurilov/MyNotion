import SwiftUI

/// Прошлые чаты под заголовком панели: поиск по названию, разделы по срокам, у каждого — дата.
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
                                AIChatPopupRow(isSelected: item.id == controller.chatID, action: { controller.openChat(item.id) }) {
                                    Image(systemName: "bubble.left").font(.system(size: 12)).foregroundStyle(AIChatStyle.secondary)
                                    Text(item.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(item.updatedAt.formatted(Self.dateFormat))
                                        .fixedSize()
                                        .font(AIChatStyle.smallFont)
                                        .foregroundStyle(AIChatStyle.secondary)
                                }
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
