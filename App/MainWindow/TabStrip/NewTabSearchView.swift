import AppKit
import SwiftUI
import VisualStyle

/// Окно «Открыть в новой вкладке…» — ⌘T и «+», как у Notion 7.39 для Mac: карточка сверху посередине окна, поле
/// поиска, ниже недавние по дням («Сегодня», «Вчера» …), с запросом — выдача поиска 001. Enter или щелчок —
/// страница новой вкладкой в конце; Esc или щелчок мимо — закрыть.
struct NewTabSearchView: View {
    let source: RecentPagesSource
    let open: (UUID) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var rows: [RecentPageRow] = []
    @State private var selectedIndex = 0
    @FocusState private var isFieldFocused: Bool

    /// Ширина карточки ≈ левой части окна Notion (у Notion справа ещё просмотр страницы); отступ сверху — по снимку.
    static let width: CGFloat = 600
    static let maxListHeight: CGFloat = 480
    static let topInset: CGFloat = 118

    var body: some View {
        ZStack(alignment: .top) {
            // Щелчок мимо карточки закрывает её и не доходит до страницы.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            card
                .padding(.top, Self.topInset)
        }
        .onAppear {
            rows = source.recent()
            isFieldFocused = true
        }
        .onChange(of: query) { _, query in
            rows = query.trimmingCharacters(in: .whitespaces).isEmpty ? source.recent() : source.search(query)
            selectedIndex = 0
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            field
            Rectangle().fill(Color(nsColor: Palette.popupDivider)).frame(height: 1)
            list
        }
        .frame(width: Self.width)
        .background(Color(nsColor: Palette.popupMenuBackground), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: Palette.border)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-tab-search")
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
            TextField("Открыть в новой вкладке…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isFieldFocused)
                .onSubmit(openSelected)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) {
                    dismiss()
                    return .handled
                }
                .accessibilityIdentifier("new-tab-search-field")
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var list: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text(query.isEmpty ? "Недавних страниц пока нет" : "Ничего не найдено")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(nsColor: Palette.textSecondary))
                            .padding(12)
                    } else if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        let groups = RecentPagesSource.grouped(rows)
                        ForEach(groups, id: \.title) { group in
                            sectionTitle(group.title)
                            ForEach(group.rows) { row in rowView(row) }
                        }
                    } else {
                        ForEach(rows) { row in rowView(row) }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: Self.maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedIndex) { _, index in
                if rows.indices.contains(index) { scroll.scrollTo(rows[index].id) }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(nsColor: Palette.textSecondary))
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func rowView(_ row: RecentPageRow) -> some View {
        RecentPageListRow(row: row, isSelected: rows.firstIndex(of: row) == selectedIndex)
            .id(row.id)
            .onTapGesture { open(row.pageId) }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .handled }
        selectedIndex = min(max(0, selectedIndex + step), rows.count - 1)
        return .handled
    }

    private func openSelected() {
        guard rows.indices.contains(selectedIndex) else { return }
        open(rows[selectedIndex].pageId)
    }
}
