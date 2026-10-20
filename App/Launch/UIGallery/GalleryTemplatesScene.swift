import AppKit
import NotesCore
import UIGallery

/// Шаблоны в галерее (US7): образец «Шаблоны» из эталона 003 и пустая страница, на которой они предлагаются.
@MainActor
enum GalleryTemplatesScene {
    private static let extraTemplateTitles = ["Шаблон: отчёт", "Шаблон: список дел", "Шаблон: идеи"]
    private static var emptyPageId: UUID?

    static func show(_ kind: GalleryTemplates, model: MainWindowModel, library: GalleryLibrary, window: NSWindow) async -> String? {
        do {
            try PagesNavigationSample(imageProps: .empty).ensure(in: model.store)
            try markTemplates(extra: kind == .searchPopover, in: model.store)
        } catch {
            return "образец шаблонов не записался: \(error.localizedDescription)"
        }
        switch kind {
        case .sidebarSection:
            model.library.reloadTree()
            model.select(library.sample.page.id)
        case .emptyPageRows, .searchPopover:
            let page = try? model.store.write { try $0.createPage(title: "") }
            guard let page else { return "пустая страница не создалась" }
            emptyPageId = page.id
            model.library.reloadTree()
            model.select(page.id)
        }
        try? await Task.sleep(for: .milliseconds(400))
        window.makeFirstResponder(nil)
        if kind == .searchPopover {
            guard let more = find("template-rows-more", in: window.contentView) else { return "нет строки «Ещё шаблоны…»" }
            _ = more.accessibilityPerformPress()
            try? await Task.sleep(for: .milliseconds(400))
        }
        return nil
    }

    /// Шаблоны образца помечены; для `extra` — ещё три, чтобы строк стало больше пяти.
    private static func markTemplates(extra: Bool, in store: NotesStore) throws {
        try store.write { tx in
            for var page in try tx.allPages() where page.parentId == nil && page.trashedAt == nil {
                guard page.title.hasPrefix("Шаблон: "), !page.isTemplate else { continue }
                page.isTemplate = true
                try tx.updatePage(page)
            }
            guard extra else { return }
            let existing = Set(try tx.allPages().map(\.title))
            for title in extraTemplateTitles where !existing.contains(title) {
                var page = try tx.createPage(title: title, icon: "📄")
                page.isTemplate = true
                try tx.updatePage(page)
            }
        }
    }

    /// Шаблоны снова обычные страницы, пустая страница — в корзине: остальные снимки без строк шаблонов.
    static func tearDown(model: MainWindowModel) {
        let emptyId = emptyPageId
        emptyPageId = nil
        try? model.store.write { tx in
            for var page in try tx.allPages() {
                var changed = false
                if page.isTemplate { page.isTemplate = false; changed = true }
                if page.id == emptyId { page.trashedAt = Date(); changed = true }
                if changed { try tx.updatePage(page) }
            }
        }
        model.library.reloadTree()
    }

    private static func find(_ identifier: String, in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityIdentifier() == identifier { return view }
        for child in view.subviews {
            if let found = find(identifier, in: child) { return found }
        }
        return nil
    }
}
