import NotesCore
import PageEditor
import PageTree
import SwiftUI
import VisualStyle

/// Главное окно: дерево страниц слева, открытая страница справа.
struct MainWindowView: View {
    let library: Result<MainWindowModel, any Error>
    let options: LaunchOptions

    var body: some View {
        switch library {
        case .success(let model):
            PagesWindow(model: model, onEditorReady: editorReady)
        case .failure(let error):
            Text("Не удалось открыть записи: \(error.localizedDescription)")
                .foregroundStyle(Color(nsColor: Palette.textSecondary))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { DispatchQueue.main.async { editorReady() } }
        }
    }

    /// Окно на экране и принимает ввод: метка для замеров и, по флагу, снимок окна.
    private func editorReady() {
        if options.presence == .background { BackgroundWindows.orderInBehindEverything() }
        LaunchMilestones.editorReady(reportTo: options.launchReportURL)
        if let snapshotURL = options.windowSnapshotURL {
            WindowSnapshot.capture(to: snapshotURL, hoveredSidebarRow: options.hoveredSidebarRow)
        }
        if let galleryURL = options.uiGalleryURL {
            switch library {
            case .success(let model): UIGalleryRunner.editorReady(model: model, prepared: AppDelegate.galleryLibrary, folder: galleryURL,
                                                                  filter: options.uiGalleryFilter)
            case .failure(let error):
                FileHandle.standardError.write(Data("Галерея: база не открылась: \(error)\n".utf8))
                NSApp.terminate(nil)
            }
        }
        if let benchmarkURL = options.typingBenchmarkURL, case .success(let model) = library {
            TypingBenchmark.editorReady(model: model, reportTo: benchmarkURL)
        }
    }
}

private struct PagesWindow: View {
    @Bindable var model: MainWindowModel
    let onEditorReady: @MainActor () -> Void
    @Environment(\.undoManager) private var undoManager
    /// Ширина в начале перетаскивания края панели.
    @State private var widthAtDragStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: model.sidebarWidth)
            sidebarEdge
            pageArea
                .frame(maxWidth: .infinity)
        }
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
                select: { model.select($0) },
                rename: { model.rename($0, to: $1) },
                move: { model.move($0, toParent: $1, at: $2) },
                moveToTrash: { model.moveToTrash($0) },
                addSubpage: { model.createSubpage(in: $0) },
                collapsedPagesChanged: { model.setCollapsedPages($0) }
            ),
            trashActions: TrashActions(
                restore: { model.restore($0) },
                deleteForever: { model.deleteForever($0) },
                emptyTrash: { model.emptyTrash() }
            ),
            topInset: Metrics.Page.topBarHeight
        )
    }

    /// Край панели: линия цвета border; за полосу шириной `resizeHandleWidth` панель тянут.
    private var sidebarEdge: some View {
        Rectangle()
            .fill(Color(nsColor: Palette.border))
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

    @ViewBuilder
    private var pageArea: some View {
        if let document = model.openDocument {
            PageEditorView(
                document: document,
                ancestorTitles: model.ancestorTitles(of: document.pageId),
                initialFocus: model.initialFocus,
                linkedPages: linkedPages,
                onOpenPage: { model.select($0) },
                onReady: onEditorReady
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
