import Foundation
import NotesCore
import Observation
import PageEditor
import VisualStyle

/// Состояние главного окна: дерево страниц, корзина, открытая страница и вид окна.
/// Операции с деревом идут через `PageTreeOperations` ядра; отмена — в `UndoManager` окна.
@MainActor
@Observable
final class MainWindowModel {
    let store: NotesStore
    @ObservationIgnored let openDocuments: OpenDocuments
    @ObservationIgnored let treeOperations: PageTreeOperations
    /// Дерево без корзины.
    private(set) var tree = PageTreeSnapshot(allPages: [])
    /// Меняется при каждом перечитывании дерева.
    private(set) var treeRevision = 0
    private(set) var trashEntries: [Page] = []
    private(set) var collapsedPageIds: Set<UUID> = []
    private(set) var sidebarWidth: Double = Metrics.Sidebar.defaultWidth
    /// Боковая панель спрятана шторкой (⌘⌥S).
    private(set) var isSidebarCollapsed = false
    private(set) var openDocument: PageDocument?
    /// Куда поставить курсор в только что открытой странице.
    private(set) var initialFocus: PageTextView.InitialFocus = .body
    private(set) var loadError: String?

    init(store: NotesStore) {
        self.store = store
        openDocuments = OpenDocuments(store: store)
        treeOperations = PageTreeOperations(store: store)
        let windowState = try? store.windowState(WindowState.mainWindowId)
        collapsedPageIds = windowState?.collapsedPageIds ?? []
        sidebarWidth = windowState?.sidebarWidth ?? Metrics.Sidebar.defaultWidth
        isSidebarCollapsed = windowState?.isSidebarCollapsed ?? false
        reloadTree()
        treeOperations.onChange = { [weak self] touched in self?.treeDidChange(touched) }
        treeOperations.onUndoFailure = { [weak self] error in
            self?.loadError = "Не удалось отменить: \(SaveStatus.reason(for: error))"
        }
        let lastOpen = windowState?.openPageId.flatMap { tree.page($0)?.id }
        if let pageId = lastOpen ?? tree.children(of: nil).first?.id {
            open(pageId, focus: .body, remember: false)
        }
    }

    var openPageId: UUID? { openDocument?.pageId }

    /// Название открытой страницы прямо во время набора — для дерева.
    var liveTitleOfOpenPage: String? { openDocument?.page.title }

    /// Названия предков страницы с иконками от корня — для пути в верхней полосе.
    func ancestorTitles(of pageId: UUID) -> [String] {
        tree.ancestors(of: pageId).map(\.pathTitle)
    }

    /// Отмена окна: общая для редактора и дерева.
    func attachUndoManager(_ undoManager: UndoManager?) {
        treeOperations.undoManager = undoManager
    }

    // MARK: Действия

    func select(_ pageId: UUID?, focus: PageTextView.InitialFocus = .body) {
        guard let pageId, pageId != openPageId else { return }
        open(pageId, focus: focus, remember: true)
    }

    /// ⌘N: новая страница рядом с текущей, курсор в названии (contracts/editor-interactions.md).
    func createPage() {
        do {
            let current = openPageId.flatMap { tree.page($0) }
            let siblings = tree.children(of: current.flatMap { tree.parentId(of: $0.id) })
            let nextSibling = current.flatMap { current in siblings.map(\.sortKey).filter { $0 > current.sortKey }.min() }
            let page = try store.write { transaction in
                if let current {
                    try transaction.createPage(parentId: current.parentId, after: current.sortKey, before: nextSibling)
                } else {
                    try transaction.createPage()
                }
            }
            reloadTree()
            open(page.id, focus: .title, remember: true)
        } catch {
            loadError = "Не удалось создать страницу: \(SaveStatus.reason(for: error))"
        }
    }

    /// ⇧⌘N и «+» в строке дерева: подстраница внутри страницы (по умолчанию — открытой), курсор в названии.
    func createSubpage(in parentId: UUID? = nil) {
        guard let parentId = parentId ?? openPageId else { return createPage() }
        if collapsedPageIds.remove(parentId) != nil {
            saveWindowState { $0.collapsedPageIds = collapsedPageIds }
        }
        if let subpage = performTreeOperation({ try treeOperations.createSubpage(in: parentId) }) {
            open(subpage.id, focus: .title, remember: true)
        }
    }

    func rename(_ pageId: UUID, to title: String) {
        performTreeOperation { try treeOperations.rename(pageId, to: title) }
    }

    func move(_ pageId: UUID, toParent parentId: UUID?, at index: Int) {
        performTreeOperation { try treeOperations.move(pageId, toParent: parentId, at: index) }
    }

    func moveToTrash(_ pageId: UUID) {
        performTreeOperation { try treeOperations.moveToTrash(pageId) }
    }

    func restore(_ pageId: UUID) {
        performTreeOperation { try treeOperations.restore(pageId) }
    }

    func deleteForever(_ pageId: UUID) {
        performTreeOperation { try treeOperations.deleteForever(pageId) }
    }

    func emptyTrash() {
        performTreeOperation { try treeOperations.emptyTrash() }
    }

    func setCollapsedPages(_ pageIds: Set<UUID>) {
        collapsedPageIds = pageIds
        saveWindowState { $0.collapsedPageIds = pageIds }
    }

    /// Пока тянут край панели; записывается в `saveSidebarWidth`, когда отпустили.
    func setSidebarWidth(_ width: Double) {
        sidebarWidth = min(max(width, Metrics.Sidebar.minimumWidth), Metrics.Sidebar.maximumWidth)
    }

    /// Шторка: спрятать или показать боковую панель; состояние переживает перезапуск.
    func toggleSidebar() {
        isSidebarCollapsed.toggle()
        saveWindowState { $0.isSidebarCollapsed = isSidebarCollapsed }
    }

    func saveSidebarWidth() {
        saveWindowState { $0.sidebarWidth = sidebarWidth }
    }

    /// Записать всё сейчас: уход в фон, закрытие окна, выход. `false` — что-то не записалось.
    @discardableResult
    func saveAll() -> Bool {
        openDocuments.saveAll()
    }

    var hasFailedSaves: Bool { openDocuments.hasFailedSaves }

    // MARK: Внутреннее

    /// Перед операцией правки открытой страницы уходят в базу, чтобы операция видела их.
    @discardableResult
    private func performTreeOperation<T>(_ operation: () throws -> T) -> T? {
        openDocuments.saveAll()
        do {
            return try operation()
        } catch {
            loadError = "Не удалось изменить дерево: \(SaveStatus.reason(for: error))"
            return nil
        }
    }

    /// После операции (и её отмены): перечитать дерево; открытую страницу — перечитать или сменить.
    private func treeDidChange(_ touchedPageIds: Set<UUID>) {
        reloadTree()
        guard let openPageId else {
            if let first = tree.children(of: nil).first { open(first.id, focus: .body, remember: true) }
            return
        }
        if tree.page(openPageId) == nil {
            // Открытая страница ушла в корзину или стёрта: открыть ближайшую видимую.
            let fallback = touchedPageIds.lazy.compactMap { self.tree.page($0) }.first ?? tree.children(of: nil).first
            closeOpenDocument()
            if let fallback { open(fallback.id, focus: .body, remember: true) }
        } else if touchedPageIds.contains(openPageId) {
            reopen(openPageId)
        }
    }

    private func open(_ pageId: UUID, focus: PageTextView.InitialFocus, remember: Bool) {
        do {
            let document = try openDocuments.open(pageId)
            if let previous = openDocument { openDocuments.release(previous.pageId) }
            initialFocus = focus
            openDocument = document
            loadError = nil
            if remember { saveWindowState { $0.openPageId = pageId } }
        } catch {
            loadError = "Не удалось открыть страницу: \(SaveStatus.reason(for: error))"
        }
    }

    /// Перечитать открытую страницу из базы: операция с деревом поменяла её название или ссылки.
    private func reopen(_ pageId: UUID) {
        openDocuments.release(pageId)
        openDocument = nil
        open(pageId, focus: .body, remember: false)
    }

    private func closeOpenDocument() {
        if let openDocument { openDocuments.release(openDocument.pageId) }
        openDocument = nil
        saveWindowState { $0.openPageId = nil }
    }

    /// Вид окна — локальная настройка Mac; не записался — ничего страшного.
    private func saveWindowState(_ change: (inout WindowState) -> Void) {
        var state = (try? store.windowState(WindowState.mainWindowId)) ?? WindowState(windowId: WindowState.mainWindowId)
        change(&state)
        try? store.saveWindowState(state)
    }

    private func reloadTree() {
        let all = (try? store.pageOutline()) ?? []
        tree = PageTreeSnapshot(allPages: all)
        trashEntries = NotesStore.trashEntries(in: all)
        treeRevision += 1
    }
}
