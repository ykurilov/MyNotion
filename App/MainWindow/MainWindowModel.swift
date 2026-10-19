import AppKit
import Foundation
import NotesCore
import Observation
import PageEditor
import PageSearch
import VisualStyle

/// Состояние одного окна: открытая страница, вид окна и поиск. Дерево, корзина, открытые страницы
/// и синхронизация — общие для всех окон, в `PagesLibrary` (FR-029).
/// Операции с деревом идут через `PageTreeOperations` ядра; отмена — в `UndoManager` окна.
@MainActor
@Observable
final class MainWindowModel {
    @ObservationIgnored let library: PagesLibrary
    @ObservationIgnored let treeOperations: PageTreeOperations
    /// Окно на экране: по нему библиотека знает, в каком окне работают сейчас.
    @ObservationIgnored weak var window: NSWindow?
    private(set) var collapsedPageIds: Set<UUID> = []
    private(set) var sidebarWidth: Double = Metrics.Sidebar.defaultWidth
    /// Боковая панель спрятана шторкой (⌘⌥S).
    private(set) var isSidebarCollapsed = false
    private(set) var openDocument: PageDocument?
    /// Куда поставить курсор в только что открытой странице.
    private(set) var initialFocus: PageTextView.InitialFocus = .body
    private(set) var loadError: String?
    /// Перейти к блоку открытой страницы (найденное поиском страниц): редактор раскрывает свёрнутых предков.
    /// Новый запрос — новый `token`, даже к тому же блоку.
    private(set) var blockReveal: BlockReveal?
    /// Поле поиска вверху боковой панели и его выдача (FR-018).
    @ObservationIgnored private(set) var search: PageSearchController!

    /// `opening` — страница нового окна; `nil` — последняя открытая (вид окна в базе) или первая в дереве.
    init(library: PagesLibrary, opening pageId: UUID?) {
        self.library = library
        treeOperations = PageTreeOperations(store: library.store)
        let windowState = try? library.store.windowState(WindowState.mainWindowId)
        collapsedPageIds = windowState?.collapsedPageIds ?? []
        sidebarWidth = windowState?.sidebarWidth ?? Metrics.Sidebar.defaultWidth
        isSidebarCollapsed = windowState?.isSidebarCollapsed ?? false
        treeOperations.onChange = { [weak library] touched in library?.treeDidChange(touched) }
        treeOperations.onIconChange = { [weak library] pageId, _ in library?.iconDidChange(pageId) }
        treeOperations.onUndoFailure = { [weak self] error in
            self?.loadError = "Не удалось отменить: \(SaveStatus.reason(for: error))"
        }
        search = PageSearchController(store: library.store, tree: { [weak library] in library?.tree ?? PageTreeSnapshot(allPages: []) },
                                      open: { [weak self] in self?.select($0) })
        search.openResult = { [weak self] result in self?.select(result.pageId, revealing: result.blockId) }
        library.register(self)
        let tree = library.tree
        let lastOpen = (pageId ?? windowState?.openPageId).flatMap { tree.page($0)?.id }
        if let pageId = lastOpen ?? tree.children(of: nil).first?.id {
            open(pageId, focus: .body, remember: false)
        }
    }

    var store: NotesStore { library.store }
    var openDocuments: OpenDocuments { library.openDocuments }
    var tree: PageTreeSnapshot { library.tree }
    var treeRevision: Int { library.treeRevision }
    var trashEntries: [Page] { library.trashEntries }
    var sync: SyncController! { library.sync }
    /// Настройки синхронизации — карточкой поверх этого окна (⌘, или «Настройки синхронизации…» у значка).
    var isSyncSettingsShown = false
    /// Галерея показывает в карточке настроек свой образец вместо настоящего подключения.
    var syncSettingsPreview: SyncController?

    /// Окно закрыли: его страница больше не держится открытой (записывается, если других окон с ней нет).
    func windowClosed() {
        if let openDocument { openDocuments.release(openDocument.pageId) }
        openDocument = nil
        library.unregister(self)
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

    /// Открыть страницу и перейти к блоку (поиск страниц, US1): свёрнутые предки блока раскрываются.
    func select(_ pageId: UUID, revealing blockId: UUID?) {
        select(pageId)
        guard let blockId, openPageId == pageId else { return }
        blockReveal = BlockReveal(blockId: blockId, token: (blockReveal?.token ?? 0) + 1)
    }

    /// Вид блоков этого Mac — свёрнутые переключатели.
    var blockViewState: BlockViewStateStore { BlockViewStateStore(database: store.database) }

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
            library.reloadTree()
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

    /// Иконка страницы из шапки или из боковой панели (`nil` — убрать); ⌘Z отменяет (FR-034).
    func setIcon(_ pageId: UUID, to icon: String?) {
        performTreeOperation { try treeOperations.setIcon(pageId, to: icon) }
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

    /// Импорт из Notion добавил ветку: перечитать дерево и открыть её корень.
    func showImportedBranch(_ rootPageId: UUID) {
        library.reloadTree()
        select(rootPageId)
    }

    /// Записать всё сейчас: уход в фон, закрытие окна, выход. `false` — что-то не записалось.
    @discardableResult
    func saveAll() -> Bool {
        library.saveAll()
    }

    /// Юрий выбрал версию в «Двух версиях»: конфликт снят, правка уйдёт на другие Mac.
    func resolveConflict(_ conflict: Conflict, in document: PageDocument) {
        do {
            try store.write { try $0.resolveConflict(conflict.id) }
            document.replacePendingConflicts(try store.unresolvedConflicts(ofPage: document.pageId))
        } catch {
            loadError = "Не удалось записать выбор версии: \(SaveStatus.reason(for: error))"
        }
    }

    // MARK: От библиотеки

    /// Правки с другого Mac легли в базу; открытая страница их уже приняла (research R5), дерево перечитано.
    /// Если открытая страница ушла в корзину или стёрта — открыть другую.
    func remoteChangesApplied() {
        if let openPageId, tree.page(openPageId) != nil { return }
        if openPageId != nil { closeOpenDocument() }
        // Пустой Mac получил первые страницы — открыть первую, как при запуске.
        if let first = tree.children(of: nil).first { open(first.id, focus: .unchanged, remember: true) }
    }

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

    /// Операция задела открытую страницу (название, ссылки): отпустить её документ, чтобы перечитать из базы.
    /// Отпускают все окна сразу — иначе второе окно отдало бы первому прежний документ. Возвращает, что перечитать.
    func releaseIfTouched(_ touchedPageIds: Set<UUID>) -> UUID? {
        guard let openPageId, tree.page(openPageId) != nil, touchedPageIds.contains(openPageId) else { return nil }
        openDocuments.release(openPageId)
        openDocument = nil
        return openPageId
    }

    /// После операции в любом окне (и её отмены) дерево перечитано: открытую страницу — перечитать или сменить.
    func treeDidChange(_ touchedPageIds: Set<UUID>, reopening releasedPageId: UUID?) {
        if let releasedPageId { return open(releasedPageId, focus: .body, remember: false) }
        guard let openPageId else {
            if let first = tree.children(of: nil).first { open(first.id, focus: .body, remember: true) }
            return
        }
        if tree.page(openPageId) == nil {
            // Открытая страница ушла в корзину или стёрта: открыть ближайшую видимую.
            let fallback = touchedPageIds.lazy.compactMap { self.tree.page($0) }.first ?? tree.children(of: nil).first
            closeOpenDocument()
            if let fallback { open(fallback.id, focus: .body, remember: true) }
        }
    }

    private func open(_ pageId: UUID, focus: PageTextView.InitialFocus, remember: Bool) {
        do {
            let document = try openDocuments.open(pageId)
            if let previous = openDocument { openDocuments.release(previous.pageId) }
            initialFocus = focus
            blockReveal = nil
            openDocument = document
            loadError = nil
            if remember { saveWindowState { $0.openPageId = pageId } }
        } catch {
            loadError = "Не удалось открыть страницу: \(SaveStatus.reason(for: error))"
        }
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
}
