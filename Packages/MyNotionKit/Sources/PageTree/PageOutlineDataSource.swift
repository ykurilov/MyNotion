import AppKit
import NotesCore
import VisualStyle

/// Что дерево просит сделать окно. Сами операции живут в `PageTreeOperations` ядра.
@MainActor
public struct PageTreeActions {
    public var select: (UUID) -> Void
    public var rename: (UUID, String) -> Void
    /// Страница, новый родитель (`nil` — корень), место среди новых соседей.
    public var move: (UUID, UUID?, Int) -> Void
    public var moveToTrash: (UUID) -> Void
    public var addSubpage: (UUID) -> Void
    /// Набор свёрнутых веток изменился.
    public var collapsedPagesChanged: (Set<UUID>) -> Void

    public init(
        select: @escaping (UUID) -> Void,
        rename: @escaping (UUID, String) -> Void,
        move: @escaping (UUID, UUID?, Int) -> Void,
        moveToTrash: @escaping (UUID) -> Void,
        addSubpage: @escaping (UUID) -> Void,
        collapsedPagesChanged: @escaping (Set<UUID>) -> Void
    ) {
        self.select = select
        self.rename = rename
        self.move = move
        self.moveToTrash = moveToTrash
        self.addSubpage = addSubpage
        self.collapsedPagesChanged = collapsedPagesChanged
    }
}

/// Строка дерева. `NSOutlineView` узнаёт строки по объекту, поэтому на страницу — один объект на всё время жизни дерева.
final class PageOutlineItem: NSObject {
    let pageId: UUID

    init(pageId: UUID) {
        self.pageId = pageId
    }
}

/// Данные и поведение дерева: ветки отдаются по запросу (свёрнутая ветка не читается),
/// свёрнутость запоминается, перетаскивание — по правилам `PageDrop`.
@MainActor
final class PageOutlineDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var actions: PageTreeActions
    private(set) var tree = PageTreeSnapshot(allPages: [])
    private(set) var collapsedPageIds: Set<UUID> = []
    private var items: [UUID: PageOutlineItem] = [:]
    /// Название открытой страницы прямо во время набора.
    private var liveTitle: (pageId: UUID, title: String)?
    /// Дерево само меняет раскрытие и выбор: окну об этом сообщать не нужно.
    private var isApplyingState = false
    weak var outlineView: PageOutlineView?

    init(actions: PageTreeActions) {
        self.actions = actions
    }

    func attach(to outlineView: PageOutlineView) {
        self.outlineView = outlineView
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(renameClickedRow)
        outlineView.onRename = { [weak self] row in self?.beginRenaming(row: row) }
        outlineView.onContextMenu = { [weak self] row in
            guard let self, let pageId = self.pageId(atRow: row) else { return nil }
            return self.pageMenu(for: pageId)
        }
        outlineView.onTrash = { [weak self] row in
            guard let self, let pageId = self.pageId(atRow: row) else { return }
            self.actions.moveToTrash(pageId)
        }
    }

    // MARK: Состояние от окна

    func show(_ tree: PageTreeSnapshot, collapsedPageIds: Set<UUID>, selectedPageId: UUID?) {
        guard let outlineView else { return }
        self.tree = tree
        self.collapsedPageIds = collapsedPageIds
        items = items.filter { tree.page($0.key) != nil }
        isApplyingState = true
        defer { isApplyingState = false }
        outlineView.reloadData()
        expandOpenBranches(under: nil)
        select(selectedPageId)
    }

    func select(_ pageId: UUID?) {
        guard let outlineView else { return }
        let wasApplying = isApplyingState
        isApplyingState = true
        defer { isApplyingState = wasApplying }
        guard let pageId, tree.page(pageId) != nil else {
            outlineView.deselectAll(nil)
            return
        }
        // Открытая страница внутри свёрнутой ветки: ветку не разворачиваем, выбора просто не видно.
        let row = outlineView.row(forItem: item(for: pageId))
        if row >= 0 {
            if outlineView.selectedRow != row {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
            }
            outlineView.scrollRowToVisible(row)
        } else {
            outlineView.deselectAll(nil)
        }
    }

    func setLiveTitle(_ title: String?, of pageId: UUID?) {
        let new = zip(pageId, title).map { (pageId: $0, title: $1) }
        guard new?.pageId != liveTitle?.pageId || new?.title != liveTitle?.title else { return }
        let previous = liveTitle?.pageId
        liveTitle = new
        for id in Set([previous, new?.pageId].compactMap { $0 }) { refreshRow(of: id) }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        tree.children(of: (item as? PageOutlineItem)?.pageId).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        self.item(for: tree.children(of: (item as? PageOutlineItem)?.pageId)[index].id)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? PageOutlineItem else { return false }
        return !tree.children(of: item.pageId).isEmpty
    }

    // MARK: Перетаскивание

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let item = item as? PageOutlineItem else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.pageId.uuidString, forType: .myNotionPageId)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let draggedId = draggedPageId(info) else { return [] }
        let targetId = (item as? PageOutlineItem)?.pageId
        return PageDrop.resolve(dragged: draggedId, onto: targetId, childIndex: index, in: tree) == nil ? [] : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let draggedId = draggedPageId(info),
              let drop = PageDrop.resolve(dragged: draggedId, onto: (item as? PageOutlineItem)?.pageId, childIndex: index, in: tree)
        else { return false }
        actions.move(draggedId, drop.parentId, drop.index)
        return true
    }

    private func draggedPageId(_ info: any NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.string(forType: .myNotionPageId).flatMap(UUID.init(uuidString:))
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        PageTreeRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? PageOutlineItem, let page = tree.page(item.pageId) else { return nil }
        let cell = outlineView.makeView(withIdentifier: PageTreeCellView.identifier, owner: nil) as? PageTreeCellView
            ?? PageTreeCellView(frame: .zero)
        configure(cell, page: page, item: item)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        Metrics.Sidebar.rowPitch
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingState, let outlineView, let pageId = pageId(atRow: outlineView.selectedRow) else { return }
        actions.select(pageId)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? PageOutlineItem else { return }
        refreshRow(of: item.pageId)
        let wasApplying = isApplyingState
        isApplyingState = true
        expandOpenBranches(under: item.pageId)
        isApplyingState = wasApplying
        guard !isApplyingState, collapsedPageIds.remove(item.pageId) != nil else { return }
        actions.collapsedPagesChanged(collapsedPageIds)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? PageOutlineItem else { return }
        refreshRow(of: item.pageId)
        guard !isApplyingState, collapsedPageIds.insert(item.pageId).inserted else { return }
        actions.collapsedPagesChanged(collapsedPageIds)
    }

    // MARK: Внутреннее

    private func item(for pageId: UUID) -> PageOutlineItem {
        if let item = items[pageId] { return item }
        let item = PageOutlineItem(pageId: pageId)
        items[pageId] = item
        return item
    }

    private func pageId(atRow row: Int) -> UUID? {
        guard row >= 0 else { return nil }
        return (outlineView?.item(atRow: row) as? PageOutlineItem)?.pageId
    }

    /// Развернуть всё, что не свёрнуто, внутри уже видимой ветки, на любой глубине. Свёрнутые ветки не читаются.
    /// Уже раскрытая ветка повторно не раскрывается и сама детей не обходит — поэтому спуск здесь, а не только
    /// в `outlineViewItemDidExpand`: иначе подстраница новой подстраницы осталась бы в нераскрытой ветке.
    private func expandOpenBranches(under parentId: UUID?) {
        guard let outlineView else { return }
        for page in tree.children(of: parentId) where !collapsedPageIds.contains(page.id) && !tree.children(of: page.id).isEmpty {
            let item = item(for: page.id)
            if outlineView.isItemExpanded(item) {
                expandOpenBranches(under: page.id)
            } else {
                outlineView.expandItem(item)
            }
        }
    }

    private func configure(_ cell: PageTreeCellView, page: Page, item: PageOutlineItem) {
        let title = liveTitle.flatMap { live in
            live.pageId == page.id ? (live.title.isEmpty ? Page.untitledTitle : live.title) : nil
        } ?? page.displayTitle
        let hasChildren = !tree.children(of: page.id).isEmpty
        cell.show(page, title: title, hasChildren: hasChildren, isExpanded: outlineView?.isItemExpanded(item) ?? false)
        cell.onToggleExpanded = { [weak self] in self?.toggleExpanded(page.id) }
        cell.onAddSubpage = { [weak self] in self?.actions.addSubpage(page.id) }
        cell.onShowMenu = { [weak self] anchor in self?.showMenu(for: page.id, from: anchor) }
        cell.onRenameCommitted = { [weak self] newTitle in self?.actions.rename(page.id, newTitle) }
    }

    private func refreshRow(of pageId: UUID) {
        guard let outlineView, let page = tree.page(pageId), let item = items[pageId] else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PageTreeCellView else { return }
        configure(cell, page: page, item: item)
    }

    private func toggleExpanded(_ pageId: UUID) {
        guard let outlineView else { return }
        let item = item(for: pageId)
        if outlineView.isItemExpanded(item) {
            outlineView.collapseItem(item)
        } else {
            outlineView.expandItem(item)
        }
    }

    private func beginRenaming(row: Int) {
        guard let outlineView, row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PageTreeCellView else { return }
        cell.beginRenaming()
    }

    @objc private func renameClickedRow() {
        guard let outlineView else { return }
        beginRenaming(row: outlineView.clickedRow)
    }

    // MARK: Меню «⋯» и по правой кнопке

    private func showMenu(for pageId: UUID, from anchor: NSView) {
        let menu = pageMenu(for: pageId)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
    }

    func pageMenu(for pageId: UUID) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(PageMenuItem(title: "Переименовать") { [weak self] in
            guard let self, let outlineView = self.outlineView else { return }
            self.beginRenaming(row: outlineView.row(forItem: self.item(for: pageId)))
        })
        menu.addItem(PageMenuItem(title: "Добавить подстраницу") { [weak self] in self?.actions.addSubpage(pageId) })
        menu.addItem(.separator())
        menu.addItem(PageMenuItem(title: "Удалить в корзину") { [weak self] in self?.actions.moveToTrash(pageId) })
        return menu
    }
}

/// Пункт меню с действием-замыканием.
@MainActor
final class PageMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) не используется") }

    @objc private func runHandler() {
        handler()
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
