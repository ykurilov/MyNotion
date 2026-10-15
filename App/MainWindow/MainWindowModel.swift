import Foundation
import NotesCore
import Observation
import PageEditor

/// Состояние главного окна: какие страницы есть, какая открыта, и запись открытых страниц.
/// Список пока плоский (T027); дерево страниц — история US2.
@MainActor
@Observable
final class MainWindowModel {
    let store: NotesStore
    @ObservationIgnored let openDocuments: OpenDocuments
    /// Страницы не из корзины в порядке дерева: родитель, затем его потомки.
    private(set) var pages: [Page] = []
    private(set) var openDocument: PageDocument?
    /// Куда поставить курсор в только что открытой странице.
    private(set) var initialFocus: PageTextView.InitialFocus = .body
    private(set) var loadError: String?

    init(store: NotesStore) {
        self.store = store
        openDocuments = OpenDocuments(store: store)
        reloadPages()
        let lastOpen = (try? store.windowState(WindowState.mainWindowId))?.openPageId
        if let pageId = lastOpen.flatMap({ id in pages.first { $0.id == id }?.id }) ?? pages.first?.id {
            open(pageId, focus: .body, remember: false)
        }
    }

    var openPageId: UUID? { openDocument?.pageId }

    /// Название страницы для списка: у открытой — живое, прямо во время набора.
    func title(of page: Page) -> String {
        guard let openDocument, openDocument.pageId == page.id else { return page.displayTitle }
        return openDocument.page.displayTitle
    }

    /// Названия предков страницы от корня — для пути в верхней полосе.
    func ancestorTitles(of pageId: UUID) -> [String] {
        let byId = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        var titles: [String] = []
        var current = byId[pageId]?.parentId
        while let id = current, let parent = byId[id], titles.count < pages.count {
            titles.insert(title(of: parent), at: 0)
            current = parent.parentId
        }
        return titles
    }

    // MARK: Действия

    func select(_ pageId: UUID?) {
        guard let pageId, pageId != openPageId else { return }
        open(pageId, focus: .body, remember: true)
    }

    /// ⌘N: новая страница рядом с текущей, курсор в названии (contracts/editor-interactions.md).
    func createPage() {
        do {
            let current = openDocument.flatMap { document in pages.first { $0.id == document.pageId } }
            let nextSibling = current.flatMap { current in
                pages.filter { $0.parentId == current.parentId && $0.sortKey > current.sortKey }.map(\.sortKey).min()
            }
            let page = try store.write { transaction in
                if let current {
                    try transaction.createPage(parentId: current.parentId, after: current.sortKey, before: nextSibling)
                } else {
                    try transaction.createPage()
                }
            }
            reloadPages()
            open(page.id, focus: .title, remember: true)
        } catch {
            loadError = "Не удалось создать страницу: \(SaveStatus.reason(for: error))"
        }
    }

    /// Записать всё сейчас: уход в фон, закрытие окна, выход. `false` — что-то не записалось.
    @discardableResult
    func saveAll() -> Bool {
        openDocuments.saveAll()
    }

    var hasFailedSaves: Bool { openDocuments.hasFailedSaves }

    // MARK: Внутреннее

    private func open(_ pageId: UUID, focus: PageTextView.InitialFocus, remember: Bool) {
        do {
            let document = try openDocuments.open(pageId)
            if let previous = openDocument { openDocuments.release(previous.pageId) }
            initialFocus = focus
            openDocument = document
            loadError = nil
            if remember { rememberOpenPage(pageId) }
        } catch {
            loadError = "Не удалось открыть страницу: \(SaveStatus.reason(for: error))"
        }
    }

    /// Вид окна — локальная настройка Mac; не записался — ничего страшного, страница всё равно открыта.
    private func rememberOpenPage(_ pageId: UUID) {
        var state = (try? store.windowState(WindowState.mainWindowId)) ?? WindowState(windowId: WindowState.mainWindowId)
        state.openPageId = pageId
        try? store.saveWindowState(state)
    }

    private func reloadPages() {
        let all = ((try? store.pageOutline()) ?? []).filter { $0.trashedAt == nil }
        let children = Dictionary(grouping: all, by: \.parentId)
        var ordered: [Page] = []
        func appendBranch(_ parentId: UUID?) {
            for page in (children[parentId] ?? []).sorted(by: { $0.sortKey < $1.sortKey }) {
                ordered.append(page)
                appendBranch(page.id)
            }
        }
        appendBranch(nil)
        pages = ordered
    }
}
