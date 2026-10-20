import AppKit
import Backlinks
import Navigation
import NotesCore
import PageEditor
import SwiftUI
import VisualStyle

extension Notification.Name {
    /// Первое заполнение индекса обратных ссылок закончилось: открытые страницы перечитывают счёт.
    static let backlinkIndexDidBuild = Notification.Name("cloud.kurilov.mynotion.backlinkIndexDidBuild")
    /// Запись сменила обратные ссылки у страниц (`object` — `BacklinkTargets`): их открытые страницы перечитывают счёт.
    static let backlinksDidChange = Notification.Name("cloud.kurilov.mynotion.backlinksDidChange")
}

/// Строка «↗ N обратных ссылок» под названием открытой страницы (US5; contracts/pages-ui.md, «Обратные ссылки»).
/// Счёт читается из индекса одним запросом в фоне после открытия страницы: путь открытия страницы работы не получает,
/// строка появляется, когда счёт пришёл (и только если он больше нуля). Щелчок открывает список страниц-источников.
@MainActor
final class BacklinksAddon: PageHeaderAddon {
    private weak var model: MainWindowModel?
    private let pageId: UUID
    private weak var textView: PageTextView?
    private var row: BacklinksRow?
    private var loadTask: Task<Void, Never>?
    private let list = BacklinksListPresenter()
    nonisolated(unsafe) private var buildObserver: NSObjectProtocol?
    nonisolated(unsafe) private var changeObserver: NSObjectProtocol?

    static func factory(_ model: MainWindowModel) -> PageHeaderAddonFactory {
        { [weak model] document in BacklinksAddon(model: model, pageId: document.pageId) }
    }

    init(model: MainWindowModel?, pageId: UUID) {
        self.model = model
        self.pageId = pageId
    }

    deinit {
        loadTask?.cancel()
        if let buildObserver { NotificationCenter.default.removeObserver(buildObserver) }
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
    }

    /// Сигнал подписчика индекса после фиксации записи (поток записи) — на главный поток уведомлением, не дожидаясь его:
    /// синхронная доставка держала бы поток записи, пока главный ждёт запись (взаимная блокировка).
    nonisolated static func linksDidChange(_ targets: BacklinkTargets) {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .backlinksDidChange, object: targets) }
    }

    func install(in textView: PageTextView) {
        self.textView = textView
        buildObserver = NotificationCenter.default.addObserver(forName: .backlinkIndexDidBuild, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // Ссылку добавили или убрали на другой странице (или в другом окне, или с другого Mac) — счёт сразу, как в Notion.
        let pageId = pageId
        changeObserver = NotificationCenter.default.addObserver(forName: .backlinksDidChange, object: nil, queue: .main) { [weak self] note in
            guard let targets = note.object as? BacklinkTargets else { return }
            if case .pages(let pages) = targets, !pages.contains(pageId) { return }
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func pageDidChange(_ page: Page, in textView: PageTextView) {}

    /// Счёт читается на фоновом потоке; на главный приходит только число.
    private func reload() {
        guard let store = model?.store else { return }
        let pageId = pageId
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let count = await Task.detached(priority: .utility) { (try? Backlinks(store: store).count(of: pageId)) ?? 0 }.value
            guard !Task.isCancelled else { return }
            self?.show(count: count)
        }
    }

    private func show(count: Int) {
        guard let textView else { return }
        guard count > 0 else {
            if row != nil { textView.setUnderTitle(nil, height: BacklinksRow.height) }
            row = nil
            return
        }
        let title = Backlinks.phrase(count: count)
        if let row {
            row.show(title: title)
            return
        }
        let row = BacklinksRow(title: title)
        row.onPress = { [weak self] anchor in self?.openList(from: anchor) }
        self.row = row
        textView.setUnderTitle(row, height: BacklinksRow.height)
    }

    private func openList(from anchor: NSView) {
        guard let model else { return }
        list.present(from: anchor, model: model, pageId: pageId)
    }
}

/// Всплывающий список страниц-источников: иконка, название, путь серым; щелчок — страница на блоке со ссылкой.
@MainActor
final class BacklinksListPresenter: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    func present(from anchor: NSView, model: MainWindowModel, pageId: UUID) {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        let store = model.store
        Task { [weak self, weak anchor, weak model] in
            let sources = await Task.detached { (try? Backlinks(store: store).sources(of: pageId)) ?? [] }.value
            guard let self, let anchor, let model, anchor.window != nil else { return }
            self.show(rows(for: sources, tree: model.tree), from: anchor, model: model)
        }
    }

    private func rows(for sources: [BacklinkSource], tree: PageTreeSnapshot) -> [BacklinkListRow] {
        sources.compactMap { source in
            guard let page = tree.page(source.pageId) else { return nil }
            let path = tree.ancestors(of: page.id).map(\.pathTitle).joined(separator: " / ")
            return BacklinkListRow(source: source, icon: page.icon, title: page.displayTitle, path: path)
        }
    }

    private func show(_ rows: [BacklinkListRow], from anchor: NSView, model: MainWindowModel) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let height = min(CGFloat(rows.count) * Metrics.BacklinksRow.listRowHeight + 12, Metrics.BacklinksRow.listMaxHeight)
        let content = BacklinksListView(rows: rows) { [weak popover, weak model] source in
            popover?.close()
            model?.open(PageOpenRequest.fromClick(source.pageId, revealing: source.blockId))
        }
        .frame(width: Metrics.BacklinksRow.listWidth, height: height)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        controller.view.setFrameSize(NSSize(width: Metrics.BacklinksRow.listWidth, height: height))
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: Metrics.BacklinksRow.listWidth, height: height)
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) { popover = nil }
}

struct BacklinkListRow: Identifiable {
    let source: BacklinkSource
    let icon: String?
    let title: String
    let path: String
    var id: UUID { source.blockId }
}

private struct BacklinksListView: View {
    let rows: [BacklinkListRow]
    let onSelect: (BacklinkSource) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    BacklinkListRowView(row: row) { onSelect(row.source) }
                }
            }
            .padding(6)
        }
        .accessibilityIdentifier("backlinks-list")
    }
}

private struct BacklinkListRowView: View {
    let row: BacklinkListRow
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let icon = row.icon {
                        Text(icon).font(.system(size: 15))
                    } else {
                        Image(nsImage: DocumentGlyph.image(size: 20))
                    }
                }
                .frame(width: 20, height: 20)
                Text(row.title)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(nsColor: Palette.textPrimary))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if !row.path.isEmpty {
                    Text(row.path)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: Palette.textSecondary))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: Metrics.BacklinksRow.listRowHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: isHovered ? Palette.hoverBackground : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("backlink-item")
        .accessibilityLabel(row.title)
    }
}

/// Запуск первого заполнения индекса обратных ссылок: один раз за запуск, в фоне, после готовности редактора.
/// Когда закончено, открытые страницы перечитывают счёт.
@MainActor
enum BacklinkIndexStarter {
    private static var started = false

    static func start(store: NotesStore) {
        guard !started else { return }
        started = true
        Task.detached(priority: .utility) {
            guard (try? await BacklinkIndexBuild(store: store).runIfNeeded()) == true else { return }
            await MainActor.run { NotificationCenter.default.post(name: .backlinkIndexDidBuild, object: nil) }
        }
    }
}
