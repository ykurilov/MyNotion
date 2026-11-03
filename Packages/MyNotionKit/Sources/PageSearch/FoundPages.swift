import Foundation
import GRDB
import NotesCore

/// Где лежит найденная страница (research R14). Страницы дерева — в дереве. Строк баз и того, что внутри строк, в дереве
/// панели нет: их цепочка родителей читается из базы до страницы дерева (база или страница со встроенной базой).
/// Не показываются корзина, шаблоны строк и всё внутри них.
struct FoundPages: Sendable {
    /// То, что выдаче нужно от страницы: название и иконка для строки, название — для пути.
    struct Entry: Sendable {
        let title: String
        let icon: String?
    }

    private let tree: PageTreeSnapshot
    /// Страница вне дерева: её предки вне дерева сверху вниз и она сама, и страница дерева над ними.
    private var outside: [UUID: (anchorId: UUID, chain: [Entry])] = [:]
    private var hidden: Set<UUID> = []
    /// Глубже — цикл в данных, а не настоящая вложенность.
    private static let depthLimit = 64

    init(tree: PageTreeSnapshot) {
        self.tree = tree
    }

    /// Страница видна в поиске; цепочку страницы вне дерева запоминает для пути. Частое слово — сотни строк баз,
    /// поэтому из базы читаются только нужные поля одним заранее подготовленным запросом.
    mutating func locate(_ pageId: UUID, in db: Database) throws -> Bool {
        if let page = tree.page(pageId) {
            return !([page] + tree.ancestors(of: pageId)).contains(where: isRowTemplate)
        }
        if hidden.contains(pageId) { return false }
        if outside[pageId] != nil { return true }
        let statement = try db.cachedStatement(sql: "SELECT title, icon, parentId, trashedAt, isTemplate FROM page WHERE id = ?")
        var chain: [Entry] = []
        var currentId = pageId
        while chain.count < Self.depthLimit,
              let row = try Row.fetchOne(statement, arguments: [currentId.searchIndexText]),
              (row["trashedAt"] as DatabaseValue).isNull, !(row["isTemplate"] as Bool),
              let parentId = (row["parentId"] as String?).flatMap(UUID.init(uuidString:)) {
            chain.insert(Entry(title: row["title"], icon: row["icon"]), at: 0)
            if tree.page(parentId) != nil {
                outside[pageId] = (parentId, chain)
                return true
            }
            currentId = parentId
        }
        hidden.insert(pageId)
        return false
    }

    func entry(_ pageId: UUID) -> Entry? {
        tree.page(pageId).map { Entry(title: $0.title, icon: $0.icon) } ?? outside[pageId]?.chain.last
    }

    /// Названия предков от корня.
    func pathTitles(of pageId: UUID) -> [String] {
        guard let found = outside[pageId], let anchor = tree.page(found.anchorId) else { return tree.ancestors(of: pageId).map(\.title) }
        return (tree.ancestors(of: found.anchorId) + [anchor]).map(\.title) + found.chain.dropLast().map(\.title)
    }

    /// Шаблон строки: отмеченная страница прямо в базе (обычные шаблоны живут в корне).
    private func isRowTemplate(_ page: Page) -> Bool {
        page.isTemplate && page.parentId.map(tree.isDatabase) == true
    }
}
