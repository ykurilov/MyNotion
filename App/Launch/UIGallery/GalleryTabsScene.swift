import AppKit
import Navigation
import NotesCore
import UIGallery

/// Вкладки окна в галерее (US3): окно получает готовый набор вкладок, после снимка — снова одна.
@MainActor
enum GalleryTabsScene {
    /// Привести окно в состояние; вернуть причину, если не вышло.
    static func show(_ kind: GalleryTabs, model: MainWindowModel, library: GalleryLibrary) async -> String? {
        let pages = model.tree.pagesInTreeOrder.map(\.id)
        let sample = library.sample.page.id
        let others = pages.filter { $0 != sample }
        guard others.count >= 11 else { return "в базе галереи меньше 12 страниц" }
        switch kind {
        case .one:
            install([sample], active: 0, in: model)
        case .three:
            install([others[0], sample, others[1]], active: 1, back: [others[2]], in: model)
        case .twelve:
            install([sample] + others.prefix(11), active: 3, in: model)
        case .hover:
            install([sample, others[0], others[1]], active: 0, in: model)
            model.previewHoveredTabId = model.tabs.items[1].id
        case .sidebarHidden:
            install([others[0], sample], active: 1, in: model)
            model.toggleSidebar()
        case .newTabSearch:
            install([sample, others[0]], active: 0, in: model)
            markVisited(pages.prefix(8), in: model)
            model.showNewTabSearch()
        case .recentPages:
            install([sample], active: 0, in: model)
            markVisited(pages.prefix(8), in: model)
            model.showRecentPages()
        case .trashedPage:
            guard let trashed = model.library.trashedPagesById.values.first(where: { $0.icon != nil }) else { return "нет страницы в корзине" }
            install([sample, trashed.id], active: 1, in: model)
        }
        try? await Task.sleep(for: .milliseconds(300))
        return nil
    }

    static func tearDown(_ kind: GalleryTabs, model: MainWindowModel) async {
        model.previewHoveredTabId = nil
        model.isNewTabSearchShown = false
        if kind == .sidebarHidden { model.toggleSidebar() }
        install([model.openPageId ?? model.library.tree.children(of: nil).first?.id].compactMap { $0 }, active: 0, in: model)
        try? await Task.sleep(for: .milliseconds(150))
    }

    private static func install(_ pages: [UUID], active: Int, back: [UUID] = [], in model: MainWindowModel) {
        var items = pages.map { Tab(pageId: $0) }
        if items.indices.contains(active) { items[active].back = back.map { TabEntry(pageId: $0) } }
        model.installTabs(WindowTabs(state: TabsState(active: active, items: items), openPageId: nil))
        model.showActiveTab(focus: .unchanged)
    }

    /// Недавние с разным временем открытия: сегодня, вчера, на этой неделе, раньше.
    private static func markVisited(_ pages: some Sequence<UUID>, in model: MainWindowModel) {
        let now = Date()
        let ages: [TimeInterval] = [60, 600, 3_600, 26 * 3_600, 30 * 3_600, 3 * 86_400, 5 * 86_400, 20 * 86_400]
        try? model.store.write { transaction in
            for (pageId, age) in zip(pages, ages) {
                guard var page = try transaction.page(pageId) else { continue }
                page.visitedAt = now.addingTimeInterval(-age)
                try transaction.updatePage(page)
            }
        }
    }
}
