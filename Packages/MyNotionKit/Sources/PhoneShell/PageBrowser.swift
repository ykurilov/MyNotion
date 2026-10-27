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

    public init(store: NotesStore) {
        self.store = store
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
        let page = if let parentId { try operations.createSubpage(in: parentId) } else { try operations.createRootPage() }
        reload()
        return page
    }
}
