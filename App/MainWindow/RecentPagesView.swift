import AppKit
import Navigation
import NotesCore
import PageSearch
import SwiftUI
import VisualStyle

/// Строка списка недавних страниц и выдачи поиска: иконка, название, путь родителей, время открытия.
struct RecentPageRow: Identifiable, Equatable {
    let pageId: UUID
    let title: String
    let icon: String?
    let path: String
    let visitedAt: Date?
    /// Слово нашлось в тексте блока: переход к нему (как выдача поиска 001).
    var blockId: UUID?

    var id: UUID { pageId }
}

/// Откуда берутся строки: недавние (до 50, без корзины и шаблонов) и поиск 001.
@MainActor
struct RecentPagesSource {
    static let limit = 50

    let store: NotesStore
    let tree: PageTreeSnapshot

    func recent() -> [RecentPageRow] {
        ((try? store.recentPages(limit: Self.limit)) ?? []).compactMap { page in
            guard tree.page(page.id) != nil else { return nil }
            return RecentPageRow(pageId: page.id, title: page.title.isEmpty ? Page.untitledTitle : page.title, icon: page.icon,
                                 path: tree.ancestors(of: page.id).map { $0.title.isEmpty ? Page.untitledTitle : $0.title }.joined(separator: " / "), visitedAt: page.visitedAt)
        }
    }

    func search(_ query: String) -> [RecentPageRow] {
        ((try? PageSearch(store: store).results(for: query, in: tree)) ?? []).map { result in
            RecentPageRow(pageId: result.pageId, title: result.title.isEmpty ? Page.untitledTitle : result.title, icon: result.icon,
                          path: result.path.joined(separator: " / "), visitedAt: tree.page(result.pageId)?.visitedAt,
                          blockId: result.blockId)
        }
    }

    /// Недавние по дням, как в окне Notion «Open in new tab»: «Сегодня», «Вчера», «На этой неделе», «Раньше».
    static func grouped(_ rows: [RecentPageRow], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, rows: [RecentPageRow])] {
        var groups: [(title: String, rows: [RecentPageRow])] = []
        for row in rows {
            let title = groupTitle(of: row.visitedAt, now: now, calendar: calendar)
            if groups.last?.title == title { groups[groups.count - 1].rows.append(row) } else { groups.append((title, [row])) }
        }
        return groups
    }

    private static func groupTitle(of date: Date?, now: Date, calendar: Calendar) -> String {
        guard let date else { return "Раньше" }
        if calendar.isDate(date, inSameDayAs: now) { return "Сегодня" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Вчера" }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date > weekAgo { return "На этой неделе" }
        return "Раньше"
    }

    /// «5 мин назад», «вчера».
    static func visitText(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Иконка строки: эмодзи страницы или значок документа.
struct RecentPageIcon: View {
    let icon: String?
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let icon {
                Text(icon).font(.system(size: size - 3))
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: size - 4))
                    .foregroundStyle(Color(nsColor: Palette.sidebarIcon))
            }
        }
        .frame(width: size, height: size)
    }
}

/// «Недавние» во вкладке (US3, как Library → Recents в Notion 7.39; «Показать все» в панели): поле поиска
/// и до 50 недавних — иконка, название, путь серым, время открытия справа. Щелчок — открыть в этой вкладке,
/// ⌘-щелчок — в новой.
struct RecentPagesView: View {
    let source: RecentPagesSource
    let open: (PageOpenRequest) -> Void

    @State private var query = ""
    @State private var rows: [RecentPageRow] = []
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(TabStripItem.recentPagesTitle)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Color(nsColor: Palette.textPrimary))
                    .padding(.bottom, 20)
                searchField
                    .padding(.bottom, 12)
                if rows.isEmpty {
                    Text(query.isEmpty ? "Недавних страниц пока нет" : "Ничего не найдено")
                        .font(.system(size: 14))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                        .padding(.vertical, 8)
                }
                ForEach(rows) { row in
                    RecentPageListRow(row: row, showsTime: true)
                        .onTapGesture { open(PageOpenRequest.fromClick(row.pageId, revealing: row.blockId)) }
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: Palette.pageBackground))
        .accessibilityIdentifier("recent-pages")
        .onAppear {
            rows = source.recent()
            // Следующий оборот цикла: поле уже в окне, и фокус уходит из текста страницы в него.
            DispatchQueue.main.async { isFieldFocused = true }
        }
        .onChange(of: query) { _, query in
            rows = query.trimmingCharacters(in: .whitespaces).isEmpty ? source.recent() : source.search(query)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
            TextField("Поиск", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFieldFocused)
                .onSubmit { if let first = rows.first { open(PageOpenRequest(pageId: first.pageId, revealBlockId: first.blockId)) } }
                .accessibilityIdentifier("recent-pages-search")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Palette.searchFieldBorder)))
    }
}

/// Строка: иконка, название, « — путь» серым; справа — время открытия.
struct RecentPageListRow: View {
    let row: RecentPageRow
    var showsTime = false
    var isSelected = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            RecentPageIcon(icon: row.icon)
            (Text(row.title).font(.system(size: 14, weight: .medium)).foregroundColor(Color(nsColor: Palette.textPrimary))
             + Text(row.path.isEmpty ? "" : " — \(row.path)").font(.system(size: 12)).foregroundColor(Color(nsColor: Palette.textSecondary)))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if showsTime {
                Text(RecentPagesSource.visitText(row.visitedAt))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: Palette.textSecondary))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected || isHovered ? Color(nsColor: Palette.hoverBackground) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("recent-page-row")
        .accessibilityLabel(row.title)
    }
}
