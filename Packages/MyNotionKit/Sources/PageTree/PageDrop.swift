import AppKit
import NotesCore

/// Куда ляжет страница, брошенная в дереве (contracts/editor-interactions.md, «Боковое дерево»):
/// на страницу — внутрь, в конец; между страницами — рядом; в себя или своего потомка — нельзя.
struct PageDrop: Equatable {
    /// Новый родитель; `nil` — корень.
    let parentId: UUID?
    /// Место среди новых соседей без самой страницы.
    let index: Int

    /// Индекс `NSOutlineView` для сброса на саму строку.
    static let onItem = NSOutlineViewDropOnItemIndex

    /// `onto` — строка, на которую или внутрь которой бросают (`nil` — корень).
    static func resolve(dragged pageId: UUID, onto targetId: UUID?, childIndex: Int, in tree: PageTreeSnapshot) -> PageDrop? {
        if let targetId, tree.isPage(targetId, insideBranchOf: pageId) { return nil }
        let siblings = tree.children(of: targetId)
        guard childIndex != onItem else {
            return PageDrop(parentId: targetId, index: siblings.filter { $0.id != pageId }.count)
        }
        // Дерево считает места вместе с самой страницей; если она стоит выше места сброса, место сдвигается.
        let currentIndex = siblings.firstIndex { $0.id == pageId }
        let index = currentIndex.map { $0 < childIndex ? childIndex - 1 : childIndex } ?? childIndex
        return PageDrop(parentId: targetId, index: index)
    }
}
