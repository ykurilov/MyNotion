import AppKit
import DatabaseGrid
import DatabaseViewBar
import Databases
import Navigation
import NotesCore
import PageEditor
import VisualStyle

/// База в окне (US1, T041–T042). Блок `database` рисует фабрика видов редактора: встроенная база — в потоке страницы
/// (серое название, строка вида, сетка по пределу загрузки, «Загрузить ещё»); страница-база — тот же блок на всю
/// страницу под шапкой 003 (название, иконка, обложка), сетка со своей прокруткой. Тело страницы-базы не правится.
/// Правки идут операциями окна, где база показана (его ⌘Z).
@MainActor
final class DatabaseBlockViewFactory: BlockViewFactory {
    weak var library: PagesLibrary?
    /// Показанные базы по блоку: высота строки блока — их высота.
    private let views = NSMapTable<NSUUID, DatabaseTableView>.strongToWeakObjects()

    init(library: PagesLibrary) {
        self.library = library
    }

    /// Поставить фабрику (один раз на приложение).
    static func install(library: PagesLibrary) {
        BlockViewFactories.shared.register(DatabaseBlockViewFactory(library: library), for: .database)
    }

    func makeView(for block: Block, context: BlockViewContext) -> NSView? {
        guard let library, let databaseId = block.linkedPageId,
              let model = model(for: context.textView?.window) ?? library.activeWindow,
              let controller = DatabaseTableController(store: library.store, operations: model.databaseOperations, databaseId: databaseId)
        else { return nil }
        let mode: DatabaseTableView.Mode = DatabasePageContent.isFullPage(block) ? .page : .inline
        let view = DatabaseTableView(controller: controller, mode: mode)
        let resolve: () -> MainWindowModel? = { [weak view, weak self] in self?.model(for: view?.window) ?? self?.library?.activeWindow }
        controller.onOpenRow = { [weak controller] rowId, openMode, inNewTab in
            guard let controller else { return }
            resolve()?.openRow(rowId, mode: openMode ?? controller.openMode, inNewTab: inNewTab)
        }
        view.onOpenAsPage = { resolve()?.open(PageOpenRequest(pageId: databaseId)) }
        var actions = RowMenuActions()
        actions.isFavorite = { resolve()?.isFavorite($0) ?? false }
        actions.toggleFavorite = { resolve()?.toggleFavorite($0) }
        actions.moveTo = { resolve()?.showMovePagePicker($0) }
        view.rowMenuActions = actions
        weak var textView = context.textView
        view.onHeightChange = { textView?.relayoutDatabaseBlock(block.id) }
        if mode == .page, let scrollView = context.textView?.enclosingScrollView {
            // Окно стало выше или ниже — таблица на всю страницу тоже.
            scrollView.postsFrameChangedNotifications = true
            nonisolated(unsafe) weak var resizedText = context.textView
            let blockId = block.id
            view.hostState = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { _ in
                MainActor.assumeIsolated { resizedText?.relayoutDatabaseBlock(blockId) }
            }
        }
        views.setObject(view, forKey: block.id as NSUUID)
        return view
    }

    func height(for block: Block, width: CGFloat) -> CGFloat? { nil }

    func height(for block: Block, width: CGFloat, context: BlockViewContext) -> CGFloat? {
        if DatabasePageContent.isFullPage(block) {
            // Таблица — до низа окна: страница под ней не листается, листается сетка.
            let visible = context.textView?.enclosingScrollView?.contentSize.height ?? 700
            let top = context.textView?.bodyTop ?? 0
            return max(320, visible - top - Metrics.Page.bottomPadding)
        }
        if let view = views.object(forKey: block.id as NSUUID) { return view.fittingHeight() }
        // До показа: строк — по пределу загрузки, без чтения ячеек.
        guard let library, let databaseId = block.linkedPageId else { return nil }
        let count = (try? library.store.write { tx in
            try tx.fetchTexts(sql: "SELECT COUNT(*) FROM page WHERE parentId = ? AND trashedAt IS NULL AND isTemplate = 0",
                              arguments: [.text(databaseId.uuidString.lowercased())]).first.flatMap(Int.init)
        }) ?? 0
        let limit = 50
        return DatabaseTableView.height(rows: min(count ?? 0, limit), hasMore: (count ?? 0) > limit, mode: .inline)
    }

    private func model(for window: NSWindow?) -> MainWindowModel? {
        guard let window else { return nil }
        return library?.windowModels.first { $0.window === window }
    }
}

/// Шапка страницы-базы: тело (таблица) — не текст, его не правят и в него не ставят курсор.
@MainActor
final class DatabasePageAddon: PageHeaderAddon {
    let isDatabasePage: Bool

    init(document: PageDocument) {
        isDatabasePage = document.blocks.first.map(DatabasePageContent.isFullPage) ?? false
    }

    static func factory() -> PageHeaderAddonFactory {
        { DatabasePageAddon(document: $0) }
    }

    func install(in textView: PageTextView) {
        guard isDatabasePage else { return }
        textView.isEditable = false
    }

    func pageDidChange(_ page: Page, in textView: PageTextView) {}
}
