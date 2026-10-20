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
    /// Избранную страницу перетащили в разделе «Избранное»: страница, место среди остальных избранных.
    public var moveFavorite: (UUID, Int) -> Void = { _, _ in }
    /// Щелчок по иконке строки: открыть окно выбора иконки под этим видом (FR-034).
    public var chooseIcon: (UUID, NSView) -> Void
    /// Обработчики пунктов меню строки историй 003 по местам (избранное, дублирование, перенос, вкладка, шаблон).
    public var rowMenuHandlers: [PageRowMenuSlot: (UUID) -> Void] = [:]
    /// Страница — шаблон, в избранном: для названий пунктов меню строки.
    public var pageFlags: (UUID) -> (isTemplate: Bool, isFavorite: Bool) = { _ in (false, false) }

    public init(
        select: @escaping (UUID) -> Void,
        rename: @escaping (UUID, String) -> Void,
        move: @escaping (UUID, UUID?, Int) -> Void,
        moveToTrash: @escaping (UUID) -> Void,
        addSubpage: @escaping (UUID) -> Void,
        collapsedPagesChanged: @escaping (Set<UUID>) -> Void,
        chooseIcon: @escaping (UUID, NSView) -> Void = { _, _ in }
    ) {
        self.select = select
        self.rename = rename
        self.move = move
        self.moveToTrash = moveToTrash
        self.addSubpage = addSubpage
        self.collapsedPagesChanged = collapsedPagesChanged
        self.chooseIcon = chooseIcon
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
    /// Что показывает список: дерево «Страницы» или раздел над ним — «Избранное» (корни — избранные страницы, подстраницы
    /// раскрываются; тянуть можно только корни) и «Недавние» (плоский список).
    enum Kind { case tree, favorites, recents }

    let kind: Kind
    var actions: PageTreeActions
    private(set) var tree = PageTreeSnapshot(allPages: [])
    private(set) var collapsedPageIds: Set<UUID> = []
    /// Разделы: корни списка по порядку.
    private(set) var rootPageIds: [UUID] = []
    /// Разделы: раскрытые ветки (по умолчанию всё свёрнуто). У дерева «Страницы» наоборот — свёрнутые в `collapsedPageIds`.
    private(set) var expandedPageIds: Set<UUID> = []
    /// Раздел: раскрытие веток изменилось.
    var expandedPagesChanged: (Set<UUID>) -> Void = { _ in }
    private var items: [UUID: PageOutlineItem] = [:]
    /// Название открытой страницы прямо во время набора.
    private var liveTitle: (pageId: UUID, title: String)?
    /// Дерево само меняет раскрытие и выбор: окну об этом сообщать не нужно.
    private var isApplyingState = false
    weak var outlineView: PageOutlineView?

    init(actions: PageTreeActions, kind: Kind = .tree) {
        self.actions = actions
        self.kind = kind
    }

    func attach(to outlineView: PageOutlineView) {
        self.outlineView = outlineView
        outlineView.registerForDraggedTypes([dragType])
        switch kind {
        case .tree: break
        case .favorites: outlineView.useSectionIdentifier("favorites", label: "Избранное")
        case .recents: outlineView.useSectionIdentifier("recents", label: "Недавние")
        }
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

    func show(_ tree: PageTreeSnapshot, collapsedPageIds: Set<UUID>, selectedPageId: UUID?,
              rootPageIds: [UUID] = [], expandedPageIds: Set<UUID> = []) {
        guard let outlineView else { return }
        self.tree = tree
        self.collapsedPageIds = collapsedPageIds
        self.rootPageIds = rootPageIds
        self.expandedPageIds = expandedPageIds
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
            // Видимую строку не трогаем: прокрутка заново раскладывает видимые строки. Невидимую — показываем чуть позже:
            // сборка видов строк на новом месте (около 10 мс) не задерживает показ открытой страницы и ввод в неё
            // (замер «назад», 003); панель догоняет страницу через `revealDelay`, глазом этого не видно.
            if !outlineView.rows(in: outlineView.visibleRect).contains(row) {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDelay) { [weak self] in self?.scrollToVisible(pageId) }
            }
        } else {
            outlineView.deselectAll(nil)
        }
    }

    static let revealDelay: DispatchTimeInterval = .milliseconds(50)

    private func scrollToVisible(_ pageId: UUID) {
        guard let outlineView, tree.page(pageId) != nil else { return }
        let row = outlineView.row(forItem: item(for: pageId))
        guard row >= 0, row == outlineView.selectedRow, !outlineView.rows(in: outlineView.visibleRect).contains(row) else { return }
        outlineView.scrollRowToVisible(row)
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
        children(of: (item as? PageOutlineItem)?.pageId).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        self.item(for: children(of: (item as? PageOutlineItem)?.pageId)[index].id)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? PageOutlineItem else { return false }
        return !children(of: item.pageId).isEmpty
    }

    /// Строки под родителем; `nil` — корень. У «Недавних» подстраниц нет.
    private func children(of parentId: UUID?) -> [Page] {
        switch (kind, parentId) {
        case (.tree, _): tree.children(of: parentId)
        case (_, nil): rootPageIds.compactMap { tree.page($0) }
        case (.recents, _): []
        case (.favorites, _): tree.children(of: parentId)
        }
    }

    private var idPrefix: String {
        switch kind {
        case .tree: "page-tree"
        case .favorites: "favorites-row"
        case .recents: "recents-row"
        }
    }

    private func isCollapsed(_ pageId: UUID) -> Bool {
        kind == .tree ? collapsedPageIds.contains(pageId) : !expandedPageIds.contains(pageId)
    }

    // MARK: Перетаскивание

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let item = item as? PageOutlineItem, kind != .recents else { return nil }
        if kind == .favorites, !rootPageIds.contains(item.pageId) { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.pageId.uuidString, forType: dragType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let draggedId = draggedPageId(info) else { return [] }
        if kind != .tree {
            return favoriteDropIndex(draggedId, item: item, index: index, in: outlineView) == nil ? [] : .move
        }
        let targetId = (item as? PageOutlineItem)?.pageId
        return PageDrop.resolve(dragged: draggedId, onto: targetId, childIndex: index, in: tree) == nil ? [] : .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if kind != .tree {
            guard let draggedId = draggedPageId(info),
                  let target = favoriteDropIndex(draggedId, item: item, index: index, in: outlineView) else { return false }
            actions.moveFavorite(draggedId, target)
            return true
        }
        guard let draggedId = draggedPageId(info),
              let drop = PageDrop.resolve(dragged: draggedId, onto: (item as? PageOutlineItem)?.pageId, childIndex: index, in: tree)
        else { return false }
        actions.move(draggedId, drop.parentId, drop.index)
        return true
    }

    /// «Избранное»: куда встанет перетащенная страница среди остальных избранных. Бросок на строку — перед ней;
    /// бросок внутрь ветки или страницы не из раздела — нельзя. `nil` — бросать сюда нельзя.
    private func favoriteDropIndex(_ draggedId: UUID, item: Any?, index: Int, in outlineView: NSOutlineView) -> Int? {
        guard kind == .favorites, let from = rootPageIds.firstIndex(of: draggedId) else { return nil }
        var position = index
        if let target = item as? PageOutlineItem {
            guard let onto = rootPageIds.firstIndex(of: target.pageId) else { return nil }
            position = onto
            outlineView.setDropItem(nil, dropChildIndex: onto)
        } else if index < 0 {
            position = rootPageIds.count
            outlineView.setDropItem(nil, dropChildIndex: position)
        }
        // Индекс среди остальных: сама страница из списка уходит.
        let target = position > from ? position - 1 : position
        return target == from ? nil : target
    }

    /// Избранное тянется только внутри своего раздела: у него свой тип перетаскивания, дерево «Страницы» его не принимает.
    private var dragType: NSPasteboard.PasteboardType { kind == .favorites ? .myNotionFavoritePageId : .myNotionPageId }

    private func draggedPageId(_ info: any NSDraggingInfo) -> UUID? {
        info.draggingPasteboard.string(forType: dragType).flatMap(UUID.init(uuidString:))
    }

    // MARK: NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        PageTreeRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? PageOutlineItem, let page = tree.page(item.pageId) else { return nil }
        let cell = outlineView.makeView(withIdentifier: PageTreeCellView.identifier, owner: nil) as? PageTreeCellView
            ?? PageTreeCellView(frame: .zero, idPrefix: idPrefix)
        configure(cell, page: page, item: item)
        return cell
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
        guard !isApplyingState else { return }
        if kind != .tree {
            if expandedPageIds.insert(item.pageId).inserted { expandedPagesChanged(expandedPageIds) }
            return
        }
        guard collapsedPageIds.remove(item.pageId) != nil else { return }
        actions.collapsedPagesChanged(collapsedPageIds)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? PageOutlineItem else { return }
        refreshRow(of: item.pageId)
        guard !isApplyingState else { return }
        if kind != .tree {
            if expandedPageIds.remove(item.pageId) != nil { expandedPagesChanged(expandedPageIds) }
            return
        }
        guard collapsedPageIds.insert(item.pageId).inserted else { return }
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
        for page in children(of: parentId) where !isCollapsed(page.id) && !children(of: page.id).isEmpty {
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
        let hasChildren = !children(of: page.id).isEmpty
        cell.show(page, title: title, hasChildren: hasChildren, isExpanded: outlineView?.isItemExpanded(item) ?? false)
        cell.onToggleExpanded = { [weak self] in self?.toggleExpanded(page.id) }
        cell.onAddSubpage = { [weak self] in self?.actions.addSubpage(page.id) }
        cell.onChooseIcon = { [weak self] anchor in self?.actions.chooseIcon(page.id, anchor) }
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
        var handlers = actions.rowMenuHandlers
        handlers[.rename] = { [weak self] pageId in
            guard let self, let outlineView = self.outlineView else { return }
            self.beginRenaming(row: outlineView.row(forItem: self.item(for: pageId)))
        }
        handlers[.addSubpage] = { [weak self] in self?.actions.addSubpage($0) }
        handlers[.trash] = { [weak self] in self?.actions.moveToTrash($0) }
        let flags = actions.pageFlags(pageId)
        return PageRowMenu.make(items: PageRowMenuItem.all,
                                context: PageRowMenuContext(pageId: pageId, isTemplate: flags.isTemplate, isFavorite: flags.isFavorite),
                                handlers: handlers)
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
