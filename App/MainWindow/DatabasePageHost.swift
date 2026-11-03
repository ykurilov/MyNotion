import AppKit
import DatabaseGrid
import DatabaseViewBar
import Databases
import EmojiPicker
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
    /// Выбор иконки строки из её меню («Изменить иконку»).
    private let rowIconPicker = EmojiPickerController()

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
        // Меню колонки, «+» и окно «Свойства» (T039); окна вида — фильтр, сортировка, настройки вида (US3).
        let menus = PropertyMenuPresenter(store: library.store, operations: model.databaseOperations, databaseId: databaseId,
                                          viewId: controller.viewId)
        let panels = ViewPanels(controller: controller)
        menus.columnRect = { [weak view] propertyId in view?.columnHeaderRect(propertyId) }
        view.onColumnMenu = { property, rect, host in menus.showColumnMenu(for: property.id, below: rect, in: host) }
        view.onAddProperty = { rect, host in menus.showAddProperty(below: rect, in: host) }
        view.onViewSettings = { _, host in panels.showViewSettings(in: host, selectName: false) }
        panels.onShowProperties = { rect, host in menus.showPropertiesWindow(below: rect, in: host) }
        view.onViewCommand = { command, rect, host in
            switch command {
            case .addFilter: panels.showAddFilter(below: rect, in: host)
            case .filter(let path): panels.showFilter(at: path, below: rect, in: host)
            case .sorts: panels.showSorts(below: rect, in: host)
            case .settings(let selectName): panels.showViewSettings(in: host, selectName: selectName)
            }
        }
        view.onViewSwitch = { viewId in
            panels.close()
            menus.setViewId(viewId)
        }
        menus.onOpenFilter = { [weak view] path, propertyId in
            guard let view else { return }
            view.revealChips()
            panels.showFilter(at: path, below: view.columnHeaderRect(propertyId) ?? view.bounds, in: view)
        }
        view.grid.onCalculateMenu = { [weak view] property, rect in
            guard let view else { return }
            menus.showCalculateMenu(for: property.id, below: view.convert(rect, from: view.grid), in: view)
        }
        view.grid.onNewGroup = { [weak controller] _ in
            guard let controller, let propertyId = controller.view.groupSettings?.propertyId else { return }
            controller.editView { operations, _ in try operations.addGroupOption(to: propertyId) }
        }
        view.onEditProperty = { property, host in menus.showEditProperty(property.id, in: host) }
        var actions = RowMenuActions()
        actions.isFavorite = { resolve()?.isFavorite($0) ?? false }
        actions.toggleFavorite = { resolve()?.toggleFavorite($0) }
        actions.moveTo = { resolve()?.showMovePagePicker($0) }
        actions.changeIcon = { [weak self] rowId, anchor in
            guard let self, let window = anchor.window else { return }
            let screenRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            rowIconPicker.show(below: screenRect, in: window) { resolve()?.setIcon(rowId, to: $0) }
        }
        view.rowMenuActions = actions
        weak var textView = context.textView
        view.onHeightChange = { textView?.relayoutDatabaseBlock(block.id) }
        views.setObject(view, forKey: block.id as NSUUID)
        return view
    }

    func height(for block: Block, width: CGFloat) -> CGFloat? { nil }

    func height(for block: Block, width: CGFloat, context: BlockViewContext) -> CGFloat? {
        if let view = views.object(forKey: block.id as NSUUID) { return view.fittingHeight() }
        // До показа: строк — по пределу загрузки, без чтения ячеек.
        guard let library, let databaseId = block.linkedPageId else { return nil }
        let count = ((try? library.store.write { tx in
            try tx.fetchTexts(sql: "SELECT COUNT(*) FROM page WHERE parentId = ? AND trashedAt IS NULL AND isTemplate = 0",
                              arguments: [.text(databaseId.uuidString.lowercased())]).first.flatMap(Int.init)
        }) ?? nil) ?? 0
        // Страница-база — все строки (листается страница), встроенная — по пределу загрузки 50.
        if DatabasePageContent.isFullPage(block) { return DatabaseTableView.height(rows: count, hasMore: false, mode: .page) }
        let limit = 50
        return DatabaseTableView.height(rows: min(count, limit), hasMore: count > limit, mode: .inline)
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
        // Без курсора в теле: в нём только таблица.
        textView.isSelectable = false
    }

    func pageDidChange(_ page: Page, in textView: PageTextView) {}
}

extension MainWindowModel {
    /// «+ Добавить свойство» на странице строки: окно типов под кнопкой, свойство — в базу строки.
    func addRowProperty(_ rowId: UUID, anchor: NSView) {
        guard let databaseId = try? store.write({ try $0.page(rowId)?.parentId }) else { return }
        let menus = PropertyMenuPresenter(store: store, operations: databaseOperations, databaseId: databaseId, viewId: nil)
        rowPropertyMenus = menus
        menus.showAddProperty(below: anchor.bounds, in: anchor)
    }
}
