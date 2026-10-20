import EmojiPicker
import Navigation
import NotesCore
import PageEditor
import PageSearch
import PageTree
import ServiceLaunch
import SwiftUI
import VisualStyle

/// Окно страниц: дерево слева, открытая страница справа. Окон может быть несколько (FR-029, «Файл → Новое окно»).
struct MainWindowView: View {
    /// Сцена окон страниц: «Новое окно» открывает ещё одно.
    static let sceneId = "pages"

    let library: Result<PagesLibrary, any Error>
    let options: LaunchOptions
    /// Уведомление о выгрузке в Markdown; `nil` — выгрузки нет.
    var exportController: MarkdownExportController?
    /// Ход и отчёт импорта из Notion; `nil` — импорта нет.
    var importController: NotionImportController?

    var body: some View {
        content
            // Кнопки окна — на месте Notion (visual-style.md, «Боковая панель»).
            .background(TrafficLightsAnchor())
    }

    @ViewBuilder
    private var content: some View {
        switch library {
        case .success(let library):
            WindowContent(library: library, exportController: exportController, importController: importController,
                          onEditorReady: editorReady)
        case .failure(let error):
            Text("Не удалось открыть записи: \(error.localizedDescription)")
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { DispatchQueue.main.async { editorReady(nil) } }
        }
    }

    /// Окно на экране и принимает ввод: метка для замеров и, по флагу, снимок окна.
    /// Замеры, галерея и снимки идут в первом окне — других окон в служебных запусках нет.
    private func editorReady(_ model: MainWindowModel?) {
        if options.presence == .background { BackgroundWindows.shared.orderInMainWindow() }
        // Напоминания ставятся после готовности редактора, не при запуске (research R11); служебные запуски — без них.
        if options.allowsSync, case .success(let library) = library { library.reminders.start() }
        LaunchMilestones.editorReady(reportTo: options.launchReportURL)
        if let snapshotURL = options.windowSnapshotURL {
            WindowSnapshot.capture(to: snapshotURL, hoveredSidebarRow: options.hoveredSidebarRow)
        }
        if let galleryURL = options.uiGalleryURL {
            switch library {
            case .success(let library): UIGalleryRunner.editorReady(model: model ?? library.firstWindow, prepared: AppDelegate.galleryLibrary, folder: galleryURL,
                                                                  filter: options.uiGalleryFilter)
            case .failure(let error):
                FileHandle.standardError.write(Data("Галерея: база не открылась: \(error)\n".utf8))
                NSApp.terminate(nil)
            }
        }
        if let benchmarkURL = options.typingBenchmarkURL, case .success(let library) = library {
            TypingBenchmark.editorReady(model: model ?? library.firstWindow, reportTo: benchmarkURL)
        }
        if let benchmarkURL = options.searchBenchmarkURL, case .success(let library) = library {
            SearchBenchmark.editorReady(model: model ?? library.firstWindow, reportTo: benchmarkURL)
        }
        if let tabsURL = options.tabsBenchmarkURL, case .success(let library) = library {
            TabsBenchmark.editorReady(model: model ?? library.firstWindow, reportTo: tabsURL)
        }
        if let latencyURL = options.reminderLatencyURL, case .success(let library) = library {
            ReminderLatencyCheck.start(library: library, reportTo: latencyURL)
        }
        if let videoURL = options.videoMemoryURL {
            VideoMemoryCheck.start(window: (model ?? (try? library.get())?.firstWindow)?.window, reportTo: videoURL)
        }
    }
}

/// Как только вид попал в окно — кнопки окна на месте Notion и держатся там.
private struct TrafficLightsAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowWatcher() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowWatcher: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { TrafficLights.keepInPlace(in: window) }
        }
    }
}

extension FocusedValues {
    /// Окно, в котором работают: команды меню действуют в нём.
    @Entry var windowModel: MainWindowModel?
}

/// Своя модель у каждого окна: первому — созданная при запуске, следующим — новая над той же библиотекой.
private struct WindowContent: View {
    let library: PagesLibrary
    let exportController: MarkdownExportController?
    let importController: NotionImportController?
    let onEditorReady: @MainActor (MainWindowModel?) -> Void
    @State private var model: MainWindowModel?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let model {
                PagesWindow(model: model, exportController: exportController, importController: importController,
                            onEditorReady: { onEditorReady(model) })
                    .background(WindowReader { model.window = $0 })
                    .focusedSceneValue(\.windowModel, model)
                    .onDisappear { model.windowClosed() }
            } else {
                Color(nsColor: Palette.pageBackground)
            }
        }
        .onAppear {
            if model == nil { model = library.modelForNewWindow() }
            library.openNewWindow = { openWindow(id: MainWindowView.sceneId) }
        }
    }
}

/// Окно, в котором лежит вид: модели окна — чтобы библиотека знала, где работают сейчас.
private struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Watcher(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Watcher: NSView {
        let onWindow: @MainActor (NSWindow?) -> Void

        init(onWindow: @escaping @MainActor (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}

private struct PagesWindow: View {
    @Bindable var model: MainWindowModel
    let exportController: MarkdownExportController?
    let importController: NotionImportController?
    let onEditorReady: @MainActor () -> Void
    @Environment(\.undoManager) private var undoManager
    /// Ширина в начале перетаскивания края панели.
    @State private var widthAtDragStart: Double?
    /// Окно выбора иконки для строк боковой панели; у шапки страницы — своё в редакторе.
    @State private var sidebarIconPicker = EmojiPickerController()

    var body: some View {
        HStack(spacing: 0) {
            if !model.isSidebarCollapsed {
                HStack(spacing: 0) {
                    sidebar
                        .frame(width: model.sidebarWidth)
                        // Строка светофора над панелью тянет окно (окно за фон не тянется — US3, вкладки).
                        .background(alignment: .top) { WindowDragArea().frame(height: Metrics.Window.titleBarHeight) }
                    sidebarEdge
                }
                .transition(.move(edge: .leading))
            }
            VStack(spacing: 0) {
                // Вкладки — в строке светофора над страницей; при спрятанной панели — за шторкой (US3).
                tabStrip
                pageArea
            }
            .frame(maxWidth: .infinity)
        }
        // Шторка — у светофора и не двигается, когда панель уезжает.
        .overlay(alignment: .topLeading) { sidebarToggle }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let importController { NotionImportNoticeView(controller: importController) }
                SyncNoticeView(controller: model.sync)
                if let exportController { ExportNoticeView(controller: exportController) }
            }
        }
        .modifier(NotionImportSheets(controller: importController))
        .overlay {
            if model.isNewTabSearchShown {
                NewTabSearchView(source: RecentPagesSource(store: model.store, tree: model.tree),
                                 open: { model.openInNewTab($0) }, dismiss: { model.isNewTabSearchShown = false })
            }
        }
        .modalCard(isPresented: model.isSyncSettingsShown) {
            SyncSettingsView(controller: model.syncSettingsPreview ?? model.sync) { model.isSyncSettingsShown = false }
        }
        .animation(.easeInOut(duration: Metrics.Window.sidebarToggleDuration), value: model.isSidebarCollapsed)
        // Путь страницы — в самой верхней полосе окна, как в Notion; кнопки окна — над боковой панелью.
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { model.attachUndoManager(undoManager) }
        .onChange(of: undoManager) { _, undoManager in model.attachUndoManager(undoManager) }
        .onDisappear { model.saveAll() }
    }

    private var sidebar: some View {
        PageTreeSidebar(
            tree: model.tree,
            treeRevision: model.treeRevision,
            collapsedPageIds: model.collapsedPageIds,
            selectedPageId: model.openPageId,
            liveTitle: model.liveTitleOfOpenPage,
            trashEntries: model.trashEntries,
            actions: sidebarActions,
            trashActions: TrashActions(
                restore: { model.restore($0) },
                deleteForever: { model.deleteForever($0) },
                emptyTrash: { model.emptyTrash() }
            ),
            newPage: { model.createPage() },
            syncBadge: model.sync.badge,
            openSyncSettings: { model.isSyncSettingsShown = true },
            sections: sidebarSections,
            collapsedSections: model.collapsedSections,
            toggleSection: { model.toggleSection($0) }
        ) {
            SidebarSearchField(controller: model.search)
        }
    }

    /// Что дерево и разделы панели просят сделать окно.
    private var sidebarActions: PageTreeActions {
        var actions = PageTreeActions(
                // Фокус остаётся в дереве: стрелки, Enter и ⌘⌫ дальше работают там.
                select: { model.open(PageOpenRequest.fromClick($0), focus: .unchanged) },
                rename: { model.rename($0, to: $1) },
                move: { model.move($0, toParent: $1, at: $2) },
                moveToTrash: { model.moveToTrash($0) },
                addSubpage: { model.createSubpage(in: $0) },
                collapsedPagesChanged: { model.setCollapsedPages($0) },
                chooseIcon: { pageId, anchor in
                    guard let window = anchor.window else { return }
                    let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                    sidebarIconPicker.show(below: rect, in: window) { model.setIcon(pageId, to: $0) }
                }
        )
        actions.moveFavorite = { model.moveFavorite($0, toIndex: $1) }
        actions.rowMenuHandlers[.favorite] = { model.toggleFavorite($0) }
        actions.rowMenuHandlers[.openInNewTab] = { model.open(PageOpenRequest(pageId: $0, inNewTab: true)) }
        actions.pageFlags = { [tree = model.tree] pageId in
            let page = tree.page(pageId)
            return (isTemplate: page?.isTemplate ?? false, isFavorite: page?.favorite != nil)
        }
        return actions
    }

    /// «Недавние» и «Избранное» над деревом «Страницы»: пустой раздел не показывается.
    private var sidebarSections: [SidebarSectionContent] {
        let library = model.library
        let actions = sidebarActions
        var sections: [SidebarSectionContent] = []
        if !library.recentPageIds.isEmpty {
            sections.append(RecentSection.content(tree: model.tree, revision: model.treeRevision + library.sectionsRevision,
                                                  pageIds: library.recentPageIds, selectedPageId: model.openPageId,
                                                  liveTitle: model.liveTitleOfOpenPage, actions: actions,
                                                  showAll: { model.showRecentPages() }))
        }
        if !library.favoritePageIds.isEmpty {
            sections.append(FavoritesSection.content(tree: model.tree, revision: model.treeRevision + library.sectionsRevision,
                                                     pageIds: library.favoritePageIds, selectedPageId: model.openPageId,
                                                     liveTitle: model.liveTitleOfOpenPage, actions: actions))
        }
        return sections
    }

    /// Полоса вкладок окна (US3, contracts/pages-ui.md, «Верхняя полоса окна»).
    private var tabStrip: some View {
        TabStripView(
            items: model.tabStripItems,
            canGoBack: model.canGoBack,
            canGoForward: model.canGoForward,
            leadingInset: model.isSidebarCollapsed ? Metrics.Tabs.collapsedSidebarLeading : 0,
            previewHoveredTabId: model.previewHoveredTabId,
            actions: TabStripActions(
                back: { model.goBack() },
                forward: { model.goForward() },
                activate: { model.activateTab($0) },
                close: { model.closeTab(at: $0) },
                move: { model.moveTab(from: $0, to: $1) },
                newTab: { model.showNewTabSearch() }
            )
        )
    }

    /// Шторка: середина — на `sidebarToggleCenterX` от левого края, в строке светофора.
    private var sidebarToggle: some View {
        WindowToolbarButton(symbol: "sidebar.left", symbolSize: Metrics.Window.sidebarToggleSymbolSize,
                            label: model.isSidebarCollapsed ? "Показать боковую панель" : "Скрыть боковую панель",
                            action: { model.toggleSidebar() })
            .accessibilityIdentifier("sidebar-toggle")
            .padding(.leading, Metrics.Window.sidebarToggleCenterX - Metrics.Window.toolbarButtonSize / 2)
            .padding(.top, (Metrics.Window.titleBarHeight - Metrics.Window.toolbarButtonSize) / 2)
    }

    /// Край панели: линия цвета sidebarEdge; за полосу шириной `resizeHandleWidth` панель тянут.
    private var sidebarEdge: some View {
        Rectangle()
            .fill(Color(nsColor: Palette.sidebarEdge))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: Metrics.Sidebar.resizeHandleWidth)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let start = widthAtDragStart ?? model.sidebarWidth
                                widthAtDragStart = start
                                model.setSidebarWidth(start + drag.translation.width)
                            }
                            .onEnded { _ in
                                widthAtDragStart = nil
                                model.saveSidebarWidth()
                            }
                    )
                    .accessibilityIdentifier("sidebar-resize-handle")
            }
            .zIndex(1)
    }

    /// Что показать в блоках-подстраницах открытой страницы.
    private var linkedPages: [UUID: LinkedPage] {
        Dictionary(model.tree.pagesInTreeOrder.map { ($0.id, LinkedPage(title: $0.title, icon: $0.icon)) }) { first, _ in first }
    }

    /// Упоминания и даты открытой страницы: названия, корзина, поиск для «@», разрешение на уведомления.
    private func mentionSettings(pages: [UUID: LinkedPage]) -> MentionSettings {
        let library = model.library
        let directory = MentionDirectory(pages: pages, trashedPageIds: library.trashedPageIds,
                                         expectsMissingPages: library.sync.isEnabled,
                                         doneReminderIds: library.reminders.doneReminderIds)
        return MentionSettings(directory: directory, lookup: PageTitleLookup(search: PageSearch(store: library.store), tree: model.tree),
                               requestReminderPermission: { [reminders = library.reminders] in await reminders.requestPermission() })
    }

    @ViewBuilder
    private var pageArea: some View {
        if let document = model.openDocument {
            // Справочник всех страниц — один на подстраницы и упоминания: его сборка стоит каждому открытию страницы.
            let pages = linkedPages
            PageEditorView(
                document: document,
                ancestorTitles: model.ancestorTitles(of: document.pageId),
                initialFocus: model.initialFocus,
                linkedPages: pages,
                onOpenPage: { model.open(PageOpenRequest.fromClick($0)) },
                onSubpageRequest: { model.handleSubpageRequest($0, inPage: document.pageId) },
                onSetIcon: { model.setIcon(document.pageId, to: $0) },
                onResolveConflict: { model.resolveConflict($0, in: document) },
                blockViewState: model.blockViewState,
                blockReveal: model.blockReveal,
                onReady: onEditorReady,
                mentions: mentionSettings(pages: pages),
                pageMenuItems: PageMenuItems.all(for: model, pageId: document.pageId),
                topBarAccessory: AnyView(FavoriteStarButton(isFavorite: model.isFavorite(document.pageId)) {
                    model.toggleFavorite(document.pageId)
                }),
                headerAddons: [PageCoverAddon.factory(model)],
                scrollPlace: model.scrollPlace,
                restoringScroll: model.restoringScroll
            )
            // Новый документ — новый редактор: страницу перечитали после операции с деревом.
            .id(ObjectIdentifier(document))
        } else if let trashed = model.activeTabTrashedPage {
            TrashedPageView(page: trashed) { model.restoreActiveTabPage() }
                .onAppear { DispatchQueue.main.async { onEditorReady() } }
        } else if model.loadError == nil, !model.tree.pagesInTreeOrder.isEmpty {
            // Вкладка без страницы (или её страница стёрта) — «Недавние».
            RecentPagesView(source: RecentPagesSource(store: model.store, tree: model.tree)) { model.open($0) }
                .onAppear { DispatchQueue.main.async { onEditorReady() } }
        } else {
            Text(model.loadError ?? "Нет страниц. ⌘N — новая страница")
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: Palette.pageBackground))
                .onAppear {
                    // Окно уже на экране и принимает ввод: страницы нет, но приложение готово.
                    DispatchQueue.main.async { onEditorReady() }
                }
        }
    }
}
