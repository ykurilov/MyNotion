import Foundation
import NotesCore
import PageEditor
import PageSearch

/// Поиск страниц для окна «@» и «[[» (research R12): по названиям через FTS5, как ⇧⌘F, без страниц корзины.
/// Пустой набор — первые страницы дерева.
@MainActor
struct PageTitleLookup: PageLookup {
    let search: PageSearch
    let tree: PageTreeSnapshot

    func pages(matching query: String, limit: Int) -> [PageLookupResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return tree.pagesInTreeOrder.prefix(limit).map { page in
                PageLookupResult(pageId: page.id, title: page.title, icon: page.icon, path: path(of: page.id))
            }
        }
        let found = (try? search.results(for: query, in: tree, limit: PageSearch.defaultLimit)) ?? []
        return found.filter { !$0.titleHighlights.isEmpty }.prefix(limit).map {
            PageLookupResult(pageId: $0.pageId, title: $0.title, icon: $0.icon, path: $0.path)
        }
    }

    private func path(of pageId: UUID) -> [String] {
        tree.ancestors(of: pageId).map(\.displayTitle)
    }
}
