import EmojiPicker
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
        if let latencyURL = options.reminderLatencyURL, case .success(let library) = library {
            ReminderLatencyCheck.start(library: library, reportTo: latencyURL)
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
                    sidebarEdge
                }
                .transition(.move(edge: .leading))
            }
            VStack(spacing: 0) {
                // Панель спрятана: над страницей строка светофора со шторкой, путь страницы — под ней.
                if model.isSidebarCollapsed {
                    Color(nsColor: Palette.pageBackground)
                        .frame(height: Metrics.Window.titleBarHeight)
                }
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
            actions: PageTreeActions(
                // Фокус остаётся в дереве: стрелки, Enter и ⌘⌫ дальше работают там.
                select: { model.select($0, focus: .unchanged) },
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
            ),
            trashActions: TrashActions(
                restore: { model.restore($0) },
                deleteForever: { model.deleteForever($0) },
                emptyTrash: { model.emptyTrash() }
            ),
            newPage: { model.createPage() },
            syncBadge: model.sync.badge,
            openSyncSettings: { model.isSyncSettingsShown = true }
        ) {
            SidebarSearchField(controller: model.search)
        }
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
    private var mentionSettings: MentionSettings {
        let library = model.library
        let directory = MentionDirectory(pages: linkedPages, trashedPageIds: library.trashedPageIds,
                                         expectsMissingPages: library.sync.isEnabled,
                                         doneReminderIds: library.reminders.doneReminderIds)
        return MentionSettings(directory: directory, lookup: PageTitleLookup(search: PageSearch(store: library.store), tree: model.tree),
                               requestReminderPermission: { [reminders = library.reminders] in await reminders.requestPermission() })
    }

    @ViewBuilder
    private var pageArea: some View {
        if let document = model.openDocument {
            PageEditorView(
                document: document,
                ancestorTitles: model.ancestorTitles(of: document.pageId),
                initialFocus: model.initialFocus,
                linkedPages: linkedPages,
                onOpenPage: { model.select($0) },
                onSetIcon: { model.setIcon(document.pageId, to: $0) },
                onResolveConflict: { model.resolveConflict($0, in: document) },
                onReady: onEditorReady,
                mentions: mentionSettings
            )
            // Новый документ — новый редактор: страницу перечитали после операции с деревом.
            .id(ObjectIdentifier(document))
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
