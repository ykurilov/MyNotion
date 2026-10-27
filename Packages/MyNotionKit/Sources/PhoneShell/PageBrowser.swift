import Foundation
import NotesCore
import Observation

/// Дерево страниц для экранов iPhone: верхний уровень, подстраницы, путь и новые страницы.
/// Как на Mac (`PageTreeSnapshot`): без корзины, шаблонов, строк баз и встроенных баз.
@MainActor
@Observable
public final class PageBrowser {
    /// Растёт при каждом перечитывании: экраны по нему обновляют списки.
    public private(set) var revision = 0
    private var tree = PageTreeSnapshot(allPages: [])

    @ObservationIgnored public let store: NotesStore
    @ObservationIgnored private let operations: PageTreeOperations
    @ObservationIgnored private let openDocuments: OpenDocuments?

    /// `openDocuments` — открытые страницы: операция с деревом пишет в базу мимо них (ссылка на подстраницу
    /// в родителе), и открытый родитель должен принять её, а не затереть своим сохранением.
    public init(store: NotesStore, openDocuments: OpenDocuments? = nil) {
        self.store = store
        self.openDocuments = openDocuments
        operations = PageTreeOperations(store: store)
        reload()
    }

    /// Перечитать дерево из базы: после правок синхронизации и после своих операций.
    public func reload() {
        tree = ((try? store.pageTree()) ?? PageTreeSnapshot(allPages: [])).withoutTemplates()
        revision += 1
    }

    /// Подстраницы по порядку; `nil` — верхний уровень.
    public func children(of parentId: UUID?) -> [Page] {
        tree.children(of: parentId)
    }

    public func hasChildren(_ pageId: UUID) -> Bool {
        !tree.children(of: pageId).isEmpty
    }

    /// Страница из дерева; `nil` — её нет, она в корзине или это шаблон.
    public func page(_ id: UUID) -> Page? {
        tree.page(id)
    }

    /// Страницу можно показать: она есть и не в корзине (например, её не удалили на Mac, пока она открыта).
    public func isAvailable(_ id: UUID) -> Bool {
        tree.page(id) != nil
    }

    /// Предки страницы от верхнего уровня.
    public func ancestors(of id: UUID) -> [Page] {
        tree.ancestors(of: id)
    }

    /// «+»: пустая страница последней на верхнем уровне или подстраница со ссылкой в конце родителя.
    @discardableResult
    public func createPage(in parentId: UUID?) throws -> Page {
        // Несохранённое в открытых страницах — в базу до операции: дальше они примут её запись поверх своей.
        openDocuments?.saveAll()
        let page = if let parentId { try operations.createSubpage(in: parentId) } else { try operations.createRootPage() }
        if let openDocuments, let parentId {
            _ = openDocuments.applyExternalChanges(toPages: openDocuments.openPageIds.intersection([parentId, page.id]))
        }
        reload()
        return page
    }
}
