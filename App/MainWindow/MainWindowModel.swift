import AppKit
import DatabaseGrid
import Databases
import Foundation
import Navigation
import NotesCore
import Observation
import PageEditor
import PagePicker
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
    /// Операции баз (004): создание из «/», правки схемы и значений — свои шаги ⌘Z в отмене окна.
    @ObservationIgnored let databaseOperations: DatabaseOperations
    /// Окно «Переместить в…» (US4, `MainWindowModel+Copies`).
    @ObservationIgnored let movePicker = PagePickerController()
    /// Окно на экране: по нему библиотека знает, в каком окне работают сейчас.
    @ObservationIgnored weak var window: NSWindow? {
        // В строке светофора система тянет окно раньше, чем вкладка получает мышь: окно само не двигается,
        // его тянут пустые места строки (`WindowDragArea`), а вкладки перетаскиваются (US3).
        didSet { window?.isMovable = false }
    }
    private(set) var collapsedPageIds: Set<UUID> = []
    /// Свёрнутые разделы панели («Недавние», «Избранное»): вид окна, хранится на этом Mac.
    private(set) var collapsedSections: Set<SidebarSectionID> = []
    private(set) var sidebarWidth: Double = Metrics.Sidebar.defaultWidth
    /// Боковая панель спрятана шторкой (⌘⌥S).
    private(set) var isSidebarCollapsed = false
    private(set) var openDocument: PageDocument?
    /// Строка базы в просмотре сбоку или по центру (`MainWindowModel+Rows`); `nil` — просмотра нет.
    var rowPeek: RowPeek?
    /// «+ Добавить свойство» на странице строки: окно типов под кнопкой (строка, кнопка).
    /// Окно «+ Добавить свойство» страницы строки, пока оно открыто.
    @ObservationIgnored var rowPropertyMenus: PropertyMenuPresenter?
    /// Куда поставить курсор в только что открытой странице.
    var initialFocus: PageTextView.InitialFocus = .body
    private(set) var loadError: String?
    /// Перейти к блоку открытой страницы (найденное поиском страниц): редактор раскрывает свёрнутых предков.
    /// Новый запрос — новый `token`, даже к тому же блоку.
    private(set) var blockReveal: BlockReveal?
    /// Поле поиска вверху боковой панели и его выдача (FR-018).
    @ObservationIgnored private(set) var search: PageSearchController!
    /// Вкладки окна (US3, research R5): у каждой своя страница, место прокрутки и история «назад/вперёд».
    @ObservationIgnored private(set) var tabs: WindowTabs!
    /// Меняется с каждым изменением вкладок: полоса вкладок и стрелки «‹ ›» перерисовываются.
    private(set) var tabsRevision = 0
    /// Место прокрутки открытой страницы: его читают вкладки, когда уходят со страницы.
    @ObservationIgnored let scrollPlace = PageScrollPlace()
    /// Куда встать в только что открытой странице (переключение вкладки, «назад/вперёд»).
    private(set) var restoringScroll: TabScroll?
    /// Окно «Открыть в новой вкладке» (⌘T, «+»).
    var isNewTabSearchShown = false
    /// Галерея: вкладка, над которой будто бы мышь («×»).
    var previewHoveredTabId: UUID?
    /// «История версий» открытой страницы поверх окна (US6); `nil` — закрыта.
    var versionHistory: VersionHistoryModel?
    /// Страница, которую только что восстановили из версии: над ней полоса «Страница восстановлена» (US6).
    var restoredVersionPageId: UUID?
    /// Только что скопировали ссылку на эту страницу: внизу окна «Ссылка скопирована», на кнопке-цепочке — галочка.
    private(set) var copiedLinkPageId: UUID?
    @ObservationIgnored private var copiedLinkReset: Task<Void, Never>?
    /// Вкладки хранит только первое окно: вид окна в базе один (`WindowState.mainWindowId`).
    @ObservationIgnored private let restoresTabs: Bool
    /// Страницу перечитали после операции с деревом: встать на прежнее место.
    @ObservationIgnored private var scrollBeforeReload: TabScroll?
    /// Куда поставить курсор, когда операция перечитывает открытую страницу (заполнение по шаблону — в название).
    @ObservationIgnored var reopenFocus: PageTextView.InitialFocus?
    @ObservationIgnored private var isTabsSavePending = false
    @ObservationIgnored private var linkedPagesCache: (revision: Int, pages: [UUID: LinkedPage])?
    /// Запись открытий для «Недавних»: страница, пробывшая в активной вкладке 2 секунды или с правкой.
    @ObservationIgnored private var visits: VisitRecorder!
    /// Галерея снимков не засоряет «Недавние» открытиями, которых никто не делал.
    @ObservationIgnored var recordsVisits = true
    @ObservationIgnored private var editObserver: (any NSObjectProtocol)?

    /// `opening` — страница нового окна; `nil` — последняя открытая (вид окна в базе) или первая в дереве.
    /// `restoresTabs` — первое окно: вкладки из базы и их хранение.
    init(library: PagesLibrary, opening pageId: UUID?, restoresTabs: Bool = false) {
        self.library = library
        self.restoresTabs = restoresTabs
        treeOperations = PageTreeOperations(store: library.store)
        databaseOperations = DatabaseOperations(store: library.store)
        let windowState = try? library.store.windowState(WindowState.mainWindowId)
        collapsedPageIds = windowState?.collapsedPageIds ?? []
        collapsedSections = windowState?.collapsedSidebarSections ?? []
        sidebarWidth = windowState?.sidebarWidth ?? Metrics.Sidebar.defaultWidth
        isSidebarCollapsed = windowState?.isSidebarCollapsed ?? false
        treeOperations.onChange = { [weak library] touched in library?.treeDidChange(touched) }
        treeOperations.onIconChange = { [weak library] pageId, _ in library?.iconDidChange(pageId) }
        treeOperations.onAppearanceChange = { [weak library] pageId in library?.appearanceDidChange(pageId) }
        treeOperations.onUndoFailure = { [weak self] error in
            self?.loadError = "Не удалось отменить: \(SaveStatus.reason(for: error))"
        }
        databaseOperations.onChange = { [weak self] touched in self?.databaseDidChange(touched) }
        databaseOperations.onUndoFailure = { [weak self] error in
            self?.loadError = "Не удалось отменить: \(SaveStatus.reason(for: error))"
        }
        // Большая смена типа, прерванная падением, доводится до конца в фоне.
        databaseOperations.resumeInterruptedRewrite()
        search = PageSearchController(store: library.store, tree: { [weak library] in library?.tree ?? PageTreeSnapshot(allPages: []) },
                                      open: { [weak self] in self?.open(PageOpenRequest.fromClick($0)) })
        search.openResult = { [weak self] result in
            self?.open(PageOpenRequest.fromClick(result.pageId, revealing: result.blockId))
        }
        library.register(self)
        let tree = library.tree
        let lastOpen = (pageId ?? windowState?.openPageId).flatMap { tree.page($0)?.id }
        installTabs(WindowTabs(state: restoresTabs ? windowState?.tabs : nil, openPageId: lastOpen))
        visits = VisitRecorder(store: library.store, onRecorded: { [weak library] _ in library?.reloadRecents() })
        tabs.onActivePageChange = { [weak self] _, opened in
            guard let self, recordsVisits else { return }
            visits.pageOpened(opened)
        }
        // Правка открытой страницы (набор, название) — сразу запись открытия.
        editObserver = NotificationCenter.default.addObserver(forName: PageDocument.didApplyLocalEdits, object: nil, queue: .main) { [weak self] note in
            guard let document = note.object as? PageDocument else { return }
            MainActor.assumeIsolated {
                guard let self, self.recordsVisits, document === self.openDocument else { return }
                self.visits.pageEdited(document.pageId)
            }
        }
        // При запуске открывается только активная вкладка; остальные — адрес и место прокрутки.
        if tabs.activePageId == nil, tabs.items.count == 1, tabs.activeTab.back.isEmpty, let first = tree.children(of: nil).first {
            navigate(to: first.id, focus: .body)
        } else {
            showActiveTab(focus: .body, remember: false)
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
    /// Окно «Поделиться» для этой страницы (006).
    var sharePageId: UUID?
    /// Галерея показывает в карточке настроек свой образец вместо настоящего подключения.
    var syncSettingsPreview: SyncController?

    /// Окно закрыли: его страница больше не держится открытой (записывается, если других окон с ней нет).
    func windowClosed() {
        saveTabs()
        if let editObserver { NotificationCenter.default.removeObserver(editObserver) }
        editObserver = nil
        visits.pageOpened(Optional<UUID>.none)
        closeRowPeek()
        if let openDocument { openDocuments.release(openDocument.pageId) }
        openDocument = nil
        library.unregister(self)
        // Версии всех отмеченных страниц — сразу, не дожидаясь минуты (research R11).
        library.versions.recordAllDue()
    }

    var openPageId: UUID? { openDocument?.pageId }

    /// Название открытой страницы прямо во время набора — для дерева.
    var liveTitleOfOpenPage: String? { openDocument?.page.title }

    /// Предки страницы с иконками от корня — для пути в верхней полосе.
    func breadcrumbAncestors(of pageId: UUID) -> [BreadcrumbAncestor] {
        rowBreadcrumbAncestors(of: pageId) ?? tree.ancestors(of: pageId).map(BreadcrumbAncestor.init(page:))
    }

    /// Отмена окна: общая для редактора и дерева.
    func attachUndoManager(_ undoManager: UndoManager?) {
        treeOperations.undoManager = undoManager
        databaseOperations.undoManager = undoManager
    }

    // MARK: Действия

    /// Просьба открыть страницу из панели, поиска, ссылки: с ⌘ — новой вкладкой справа, активная остаётся;
    /// иначе — переход в активной вкладке с записью в её историю.
    func open(_ request: PageOpenRequest, focus: PageTextView.InitialFocus = .body) {
        if request.inNewTab { return tabs.open(request) }
        select(request.pageId, focus: focus)
        guard let blockId = request.revealBlockId, openPageId == request.pageId else { return }
        blockReveal = BlockReveal(blockId: blockId, token: (blockReveal?.token ?? 0) + 1)
    }

    func select(_ pageId: UUID?, focus: PageTextView.InitialFocus = .body) {
        guard let pageId, pageId != openPageId else { return }
        navigate(to: pageId, focus: focus)
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
            navigate(to: page.id, focus: .title)
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
            navigate(to: subpage.id, focus: .title)
        }
    }

    /// «Страница» в меню «/» или «Преобразовать в» открытой страницы, как в Notion 7.39: подстраница со ссылкой
    /// у блока. Из «/» — сразу открыть её с курсором в названии; ⌘Z на исходной странице отменяет одним шагом.
    func handleSubpageRequest(_ request: SubpageRequest, inPage pageId: UUID) {
        if collapsedPageIds.remove(pageId) != nil {
            saveWindowState { $0.collapsedPageIds = collapsedPageIds }
        }
        switch request {
        case .createAndOpen(let placement):
            if let subpage = performTreeOperation({ try treeOperations.createSubpage(in: pageId, linkAt: placement) }) {
                navigate(to: subpage.id, focus: .title)
            }
        case .turnInto(let blockId):
            performTreeOperation { try treeOperations.turnIntoSubpage(blockId, in: pageId) }
        case .moveBlocks(let blockIds, let anchor):
            showMoveBlocksPicker(blockIds, from: pageId, anchor: anchor)
        case .createDatabase(let placement, let isInline):
            // Полностраничная открывается, как подстраница; встроенная остаётся блоком на этой странице (вид — US1).
            if let created = performTreeOperation({ try databaseOperations.createDatabase(in: pageId, isInline: isInline, linkAt: placement) }),
               !isInline {
                navigate(to: created.databaseId, focus: .title)
            }
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

    /// Щелчок по заголовку раздела панели: свернуть или раскрыть.
    func toggleSection(_ section: SidebarSectionID) {
        if !collapsedSections.insert(section).inserted { collapsedSections.remove(section) }
        saveWindowState { $0.collapsedSidebarSections = collapsedSections }
    }

    // MARK: Избранное

    func isFavorite(_ pageId: UUID) -> Bool { tree.page(pageId)?.favorite != nil }

    /// ☆ и «Добавить в избранное / Убрать из избранного».
    /// «Копировать ссылку» (значок цепочки, «•••», меню строки панели, ⌘L).
    func copyLink(_ pageId: UUID) {
        PageLinkCopy.copy(pageId)
        copiedLinkPageId = pageId
        copiedLinkReset?.cancel()
        copiedLinkReset = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copiedLinkPageId = nil
        }
    }

    func toggleFavorite(_ pageId: UUID) {
        performTreeOperation {
            if isFavorite(pageId) { try treeOperations.removeFromFavorites(pageId) } else { try treeOperations.addToFavorites(pageId) }
        }
    }

    /// Перетащили в «Избранном»: место среди остальных избранных.
    func moveFavorite(_ pageId: UUID, toIndex index: Int) {
        performTreeOperation { try treeOperations.moveFavorite(pageId, toIndex: index) }
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
    /// Страница активной вкладки ушла в корзину или стёрта — вкладка показывает заглушку или «Недавние» (US3).
    func remoteChangesApplied() {
        if let rowPeek, !isLiveRow(rowPeek.document.pageId) { closeRowPeek() }
        if let openPageId, tree.page(openPageId) != nil || isLiveRow(openPageId) { return }
        if openPageId != nil { closeOpenDocument() }
        // Пустой Mac получил первые страницы — открыть первую, как при запуске.
        if tabs.activePageId == nil, tabs.items.count == 1, tabs.activeTab.back.isEmpty, let first = tree.children(of: nil).first {
            return navigate(to: first.id, focus: .unchanged)
        }
        showActiveTab(focus: .unchanged)
    }

    // MARK: Внутреннее

    /// Перед операцией правки открытой страницы уходят в базу, чтобы операция видела их.
    @discardableResult
    func performTreeOperation<T>(_ operation: () throws -> T) -> T? {
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
        scrollBeforeReload = scrollPlace.current()
        openDocuments.release(openPageId)
        openDocument = nil
        return openPageId
    }

    /// После операции в любом окне (и её отмены) дерево перечитано: открытую страницу — перечитать или сменить.
    /// Открытая страница ушла в корзину — вкладка показывает заглушку «Страница в корзине», стёрта — «Недавние»;
    /// вернули из корзины — снова страница (contracts/page-operations.md, «Вкладки и история»).
    func treeDidChange(_ touchedPageIds: Set<UUID>, reopening releasedPageId: UUID?) {
        if let releasedPageId {
            defer { scrollBeforeReload = nil }
            return openEditor(releasedPageId, focus: reopenFocus ?? .body, scroll: scrollBeforeReload, remember: false)
        }
        if let openPageId, tree.page(openPageId) == nil, !isLiveRow(openPageId) { closeOpenDocument() }
        // Строку из просмотра убрали в корзину или стёрли — просмотр закрывается.
        if let rowPeek, !isLiveRow(rowPeek.document.pageId) { closeRowPeek() }
        showActiveTab(focus: .body)
    }

    // MARK: Вкладки

    /// Страница вкладки в корзине: заглушка «Страница в корзине» вместо редактора.
    var activeTabTrashedPage: Page? {
        tabs.activePageId.flatMap { library.trashedPagesById[$0] }
    }

    /// Полоса вкладок: название и иконка каждой; без страницы (или стёртая) — «Недавние».
    var tabStripItems: [TabStripItem] {
        _ = tabsRevision
        return tabs.items.enumerated().map { index, tab in
            let isActive = index == tabs.activeIndex
            let page = tab.pageId.flatMap { tree.page($0) ?? library.trashedPagesById[$0] ?? library.databaseRow($0) }
            let title = isActive ? liveTitleOfOpenPage ?? page?.title : page?.title
            return TabStripItem(id: tab.id, title: page == nil ? TabStripItem.recentPagesTitle : (title?.isEmpty == false ? title! : Page.untitledTitle),
                                icon: page == nil ? .recentPages : page?.icon.map(TabStripItem.Icon.emoji) ?? .none, isActive: isActive)
        }
    }

    var canGoBack: Bool { _ = tabsRevision; return tabs.canGoBack }
    var canGoForward: Bool { _ = tabsRevision; return tabs.canGoForward }

    /// ⌘[ и «‹».
    func goBack() {
        if tabs.goBack() { showActiveTab(focus: .bodyWithoutCaret) }
    }

    /// ⌘] и «›».
    func goForward() {
        if tabs.goForward() { showActiveTab(focus: .bodyWithoutCaret) }
    }

    /// Щелчок по вкладке.
    func activateTab(_ index: Int) {
        tabs.activate(index)
        showActiveTab(focus: .bodyWithoutCaret)
    }

    /// ⌃⇥.
    func showNextTab() {
        tabs.showNextTab()
        showActiveTab(focus: .bodyWithoutCaret)
    }

    /// ⌃⇧⇥.
    func showPreviousTab() {
        tabs.showPreviousTab()
        showActiveTab(focus: .bodyWithoutCaret)
    }

    /// Перетаскивание вкладки.
    func moveTab(from source: Int, to destination: Int) {
        tabs.move(from: source, to: destination)
    }

    /// «×» на вкладке; ⌘W — активная. Последняя вкладка закрывает окно (как ⌘W 001).
    func closeTab(at index: Int) {
        switch tabs.close(at: index) {
        case .closed: showActiveTab(focus: .body)
        case .closeWindow: window?.performClose(nil)
        }
    }

    func closeActiveTab() { closeTab(at: tabs.activeIndex) }

    /// ⇧⌘T.
    func reopenClosedTab() {
        if tabs.reopenClosedTab() { showActiveTab(focus: .body) }
    }

    var hasClosedTabs: Bool { _ = tabsRevision; return !tabs.closedTabs.isEmpty }

    /// ⌘T и «+»: окно «Открыть в новой вкладке».
    func showNewTabSearch() {
        isNewTabSearchShown = true
    }

    /// Страница, выбранная в окне «Открыть в новой вкладке», — новой вкладкой в конце.
    func openInNewTab(_ pageId: UUID) {
        isNewTabSearchShown = false
        tabs.openNewTab(pageId)
        showActiveTab(focus: .body)
    }

    /// «Показать все» в разделе «Недавние» панели: «Недавние» в этой вкладке.
    func showRecentPages() {
        tabs.showRecentPages()
        showActiveTab(focus: .body)
    }

    /// «Вернуть» на заглушке «Страница в корзине»: запись корзины со страницей вкладки.
    func restoreActiveTabPage() {
        guard let pageId = tabs.activePageId, let entry = library.trashEntry(containing: pageId) else { return }
        restore(entry)
    }

    /// Вкладки окна: при запуске — из базы; галерея ставит свои.
    func installTabs(_ tabs: WindowTabs) {
        // Подписка на «ушли / открыта» (запись недавних) переходит к новым вкладкам.
        if let previous = self.tabs { tabs.onActivePageChange = previous.onActivePageChange }
        tabs.currentScroll = { [weak self] in self?.scrollPlace.current() }
        tabs.showsEditor = { [weak self] in self?.scrollPlace.showsEditor(of: $0) ?? false }
        tabs.isGone = { [weak library] in library?.isDeletedForever($0) ?? false }
        tabs.onChange = { [weak self] in self?.tabsDidChange() }
        self.tabs = tabs
        tabsRevision += 1
    }

    private func tabsDidChange() {
        tabsRevision += 1
        guard restoresTabs, !isTabsSavePending else { return }
        // Запись — после показа страницы и одна на серию переключений: на пути переключения вкладки она не нужна.
        // Выход, уход в фон и закрытие окна записывают вкладки сразу (`saveTabs`).
        isTabsSavePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self else { return }
            isTabsSavePending = false
            saveWindowState { $0.tabs = self.tabs.savedState }
        }
    }

    /// Справочник страниц для блоков-подстраниц и упоминаний: собирается заново только после смены дерева,
    /// а не при каждой перерисовке окна (переход и переключение вкладки).
    var linkedPages: [UUID: LinkedPage] {
        if let cache = linkedPagesCache, cache.revision == treeRevision { return cache.pages }
        let pages = Dictionary(tree.pagesInTreeOrder.map { ($0.id, LinkedPage(title: $0.title, icon: $0.icon)) }) { first, _ in first }
        linkedPagesCache = (treeRevision, pages)
        return pages
    }

    /// Вкладки с местом прокрутки открытой страницы — в базу сразу (уход в фон, выход, закрытие окна), не дожидаясь
    /// отложенной записи. И когда редактора нет: активная вкладка — «Недавние» или заглушка корзины.
    func saveTabs() {
        if restoresTabs { saveWindowState { $0.tabs = tabs.savedState } }
    }

    /// Переход в активной вкладке: история вкладки, затем её страница.
    func navigate(to pageId: UUID, focus: PageTextView.InitialFocus) {
        tabs.open(PageOpenRequest(pageId: pageId))
        showActiveTab(focus: focus)
    }

    /// Показать страницу активной вкладки: редактор — только у страницы из дерева; «Недавние», корзина и стёртая
    /// страница редактора не держат.
    func showActiveTab(focus: PageTextView.InitialFocus, remember: Bool = true) {
        // Страница не из дерева — в корзине (заглушка) или стёрта («Недавние»: открыть её не выйдет). Страницу,
        // записанную в обход операций дерева (замеры, импорт), редактор открывает, как раньше.
        guard let pageId = tabs.activePageId, library.trashedPagesById[pageId] == nil else {
            if openDocument != nil { closeOpenDocument() }
            return
        }
        guard pageId != openDocument?.pageId else { return }
        openEditor(pageId, focus: focus, scroll: tabs.activeTab.scroll, remember: remember)
    }

    private func openEditor(_ pageId: UUID, focus: PageTextView.InitialFocus, scroll: TabScroll?, remember: Bool) {
        do {
            let document = try openDocuments.open(pageId)
            if let previous = openDocument {
                let renamed = tree.page(previous.pageId).map { $0.title != previous.page.title || $0.icon != previous.page.icon } ?? false
                openDocuments.release(previous.pageId)
                // Название меняли в шапке: упоминания и подстраницы на других страницах берут его из дерева.
                if renamed { library.reloadTree() }
            }
            initialFocus = focus
            blockReveal = nil
            restoringScroll = scroll
            openDocument = document
            loadError = nil
            // Страница без версий получает снимок «как было» (US6, research R11).
            library.versions.pageOpened(pageId)
            // Файлы открытой страницы — первыми в очереди скачивания (FR-120).
            library.sync.prioritizeFiles(onPage: pageId)
            // Запись — после показа страницы: на пути перехода она не нужна (как запись вкладок).
            if remember {
                DispatchQueue.main.async { [weak self] in
                    guard let self, openDocument?.pageId == pageId else { return }
                    saveWindowState { $0.openPageId = pageId }
                }
            }
        } catch NotesStoreError.pageNotFound {
            // Страница стёрта: вкладка показывает «Недавние».
            if openDocument != nil { closeOpenDocument() }
        } catch {
            loadError = "Не удалось открыть страницу: \(SaveStatus.reason(for: error))"
        }
    }

    private func closeOpenDocument() {
        if let openDocument { openDocuments.release(openDocument.pageId) }
        openDocument = nil
        visits.pageOpened(Optional<UUID>.none)
        saveWindowState { $0.openPageId = nil }
    }

    /// Вид окна — локальная настройка Mac; не записался — ничего страшного.
    private func saveWindowState(_ change: (inout WindowState) -> Void) {
        var state = (try? store.windowState(WindowState.mainWindowId)) ?? WindowState(windowId: WindowState.mainWindowId)
        change(&state)
        try? store.saveWindowState(state)
    }
}
