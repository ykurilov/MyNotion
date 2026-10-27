import NotesCore
import PhoneShell
import SwiftUI

/// Главный экран: страницы верхнего уровня, подстраницы раскрываются стрелкой, касание открывает страницу.
/// Пока iPhone не подключён — предложение подключиться кодом с Mac; без подключения записи живут только здесь.
struct PageTreeScreen: View {
    let library: PhoneLibrary
    let openPage: (UUID) -> Void
    let showConnect: () -> Void
    let showSettings: () -> Void
    @State private var expanded: Set<UUID> = []

    private var browser: PageBrowser { library.browser }
    private var sync: PhoneSyncController { library.sync }

    var body: some View {
        let rows = visibleRows
        Group {
            if rows.isEmpty {
                if sync.isEnabled { waitingForPages } else { EmptyLibraryView(connect: showConnect, startLocally: createRootPage) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !sync.isEnabled { ConnectBanner(connect: showConnect).padding(.bottom, 8) }
                        ForEach(rows) { row in
                            PageTreeRow(page: row.page, depth: row.depth, hasChildren: browser.hasChildren(row.page.id),
                                        isExpanded: expanded.contains(row.page.id),
                                        toggle: { toggle(row.page.id) }, open: { openPage(row.page.id) },
                                        addSubpage: { createSubpage(in: row.page.id) })
                        }
                    }
                    .padding(.bottom, 16)
                }
                .accessibilityIdentifier("page-tree")
            }
        }
        .background(PhoneTheme.pageBackground)
        .navigationTitle("Страницы")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: showSettings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("Настройки")
                    .accessibilityIdentifier("open-settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: createRootPage) { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("Новая страница")
                    .accessibilityIdentifier("new-page")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let badge = sync.badge { SyncStatusBar(badge: badge, open: showSettings) }
        }
    }

    private var waitingForPages: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Записи приходят с ваших Mac…")
                .foregroundStyle(PhoneTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Строки

    struct Row: Identifiable {
        let page: Page
        let depth: Int
        var id: UUID { page.id }
    }

    /// Верхний уровень и раскрытые ветки — плоским списком с глубиной.
    private var visibleRows: [Row] {
        _ = browser.revision
        var rows: [Row] = []
        func append(_ parentId: UUID?, depth: Int) {
            for page in browser.children(of: parentId) {
                rows.append(Row(page: page, depth: depth))
                if expanded.contains(page.id) { append(page.id, depth: depth + 1) }
            }
        }
        append(nil, depth: 0)
        return rows
    }

    private func toggle(_ pageId: UUID) {
        if expanded.contains(pageId) { expanded.remove(pageId) } else { expanded.insert(pageId) }
    }

    private func createRootPage() {
        guard let page = try? browser.createPage(in: nil) else { return }
        openPage(page.id)
    }

    private func createSubpage(in parentId: UUID) {
        guard let page = try? browser.createPage(in: parentId) else { return }
        expanded.insert(parentId)
        openPage(page.id)
    }
}

/// Строка дерева, как в Notion для iPhone: стрелка раскрытия, иконка-эмодзи или значок документа, название.
struct PageTreeRow: View {
    let page: Page
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    let open: () -> Void
    let addSubpage: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PhoneTheme.icon)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 32, height: PhoneTheme.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hasChildren ? 1 : 0)
            .disabled(!hasChildren)
            .accessibilityLabel(isExpanded ? "Свернуть" : "Развернуть")
            Button(action: open) {
                HStack(spacing: 8) {
                    PageIcon(icon: page.icon)
                    Text(page.displayTitle)
                        .font(.system(size: PhoneTheme.rowTitleSize, weight: .medium))
                        .foregroundStyle(page.title.isEmpty ? PhoneTheme.textSecondary : PhoneTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .frame(height: PhoneTheme.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(TreeRowButtonStyle())
            .accessibilityIdentifier("page-row")
            .accessibilityLabel(page.displayTitle)
        }
        .padding(.leading, 4 + CGFloat(depth) * PhoneTheme.rowIndent)
        .padding(.trailing, 16)
        .contextMenu {
            Button("Открыть", systemImage: "doc.text", action: open)
            Button("Новая подстраница", systemImage: "plus", action: addSubpage)
        }
    }
}

struct PageIcon: View {
    let icon: String?

    var body: some View {
        Group {
            if let icon, !icon.isEmpty {
                Text(icon).font(.system(size: PhoneTheme.rowEmojiSize))
            } else {
                Image(systemName: "doc.text").font(.system(size: 17)).foregroundStyle(PhoneTheme.icon)
            }
        }
        .frame(width: PhoneTheme.rowIconSize, height: PhoneTheme.rowIconSize)
    }
}

/// Подсветка строки под пальцем — как подсветка строки дерева на Mac.
private struct TreeRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? PhoneTheme.pressedBackground : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
