import NotesCore
import PageEditor
import SwiftUI
import VisualStyle

/// Главное окно: страницы слева, открытая страница справа.
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
        LaunchMilestones.editorReady(reportTo: options.launchReportURL)
        if let snapshotURL = options.windowSnapshotURL {
            WindowSnapshot.capture(to: snapshotURL)
        }
        if let benchmarkURL = options.typingBenchmarkURL, case .success(let model) = library {
            TypingBenchmark.editorReady(model: model, reportTo: benchmarkURL)
        }
    }
}

private struct PagesWindow: View {
    @Bindable var model: MainWindowModel
    let onEditorReady: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 0) {
            PageListSidebar(model: model)
                .frame(width: Metrics.Sidebar.defaultWidth)
            Rectangle()
                .fill(Color(nsColor: Palette.border))
                .frame(width: 1)
            pageArea
                .frame(maxWidth: .infinity)
        }
        // Путь страницы — в самой верхней полосе окна, как в Notion; кнопки окна — над боковой панелью.
        .ignoresSafeArea(.container, edges: .top)
        .onDisappear { model.saveAll() }
    }

    /// Что показать в блоках-подстраницах открытой страницы.
    private var linkedPages: [UUID: LinkedPage] {
        Dictionary(model.pages.map { ($0.id, LinkedPage(title: $0.title, icon: $0.icon)) }) { first, _ in first }
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
            .id(document.pageId)
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

/// Временный плоский список страниц (T027): дерево со сворачиванием — история US2.
/// Сплошной фон, как у Notion (contracts/visual-style.md, «Боковая панель»).
private struct PageListSidebar: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.pages, id: \.id) { page in
                    row(page)
                }
            }
            .padding(.horizontal, Metrics.Sidebar.panelInset)
        }
        // Место под кнопками окна.
        .padding(.top, Metrics.Page.topBarHeight)
        .background(Color(nsColor: Palette.sidebarBackground))
    }

    private func row(_ page: Page) -> some View {
        let isOpen = page.id == model.openPageId
        return Button {
            model.select(page.id)
        } label: {
            HStack(spacing: Metrics.Sidebar.rowHorizontalPadding) {
                Text(page.icon ?? "📄")
                    .frame(width: Metrics.Sidebar.rowIconSize, height: Metrics.Sidebar.rowIconSize)
                Text(model.title(of: page))
                    .font(Font(Typography.sidebarRow.font))
                    .foregroundStyle(Color(nsColor: isOpen ? Palette.textPrimary : Palette.sidebarText))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, Metrics.Sidebar.rowVerticalPadding)
            .padding(.horizontal, Metrics.Sidebar.rowHorizontalPadding)
            .frame(height: Metrics.Sidebar.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Sidebar.rowCornerRadius)
                    .fill(isOpen ? Color(nsColor: Palette.hoverBackground) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-page")
    }
}
