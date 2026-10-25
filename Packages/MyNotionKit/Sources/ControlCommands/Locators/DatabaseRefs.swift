import ControlProtocol
import Databases
import Foundation
import GRDB
import NotesCore

/// База, найденная по указателю: страница, запись базы и свойства с вариантами.
public struct ResolvedDatabase: Sendable {
    public let page: Page
    public let schema: DatabaseSchema
    public let catalog: DatabaseCatalog
}

/// Указатели внутри базы (research R10): база — указатель страницы (страница-база или страница с одной встроенной базой);
/// свойство, вариант и вид — id или имя (без регистра, `ё` = `е`); строка — id или название среди строк базы.
@MainActor
public struct DatabaseRefs {
    let store: NotesStore
    let pages: PageLocator

    public init(store: NotesStore, pages: PageLocator) {
        self.store = store
        self.pages = pages
    }

    public func database(_ text: String, includeTrashed: Bool = false) throws(ControlError) -> ResolvedDatabase {
        let page = try pages.resolve(text, includeTrashed: includeTrashed)
        if let resolved = try resolved(page) { return resolved }
        // Обычная страница с одной встроенной базой — та база.
        let linked = try read { try store.pageContent(page.id)?.blocks ?? [] }.filter { $0.kind == .database }.compactMap(\.linkedPageId)
        if linked.count == 1, let inner = try read({ try store.page(linked[0]) }), let resolved = try resolved(inner) { return resolved }
        throw ControlError(.databaseNotFound, "«\(text)» — не база", hint: linked.count > 1
                               ? "На странице несколько баз: укажите саму базу (её id или путь)" : "Базы ищутся как страницы: mynotion search <название>",
                           details: ["page": .string(page.id.controlText)])
    }

    private func resolved(_ page: Page) throws(ControlError) -> ResolvedDatabase? {
        try read {
            try store.database.dbWriter.read { db -> ResolvedDatabase? in
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM db_database WHERE pageId = ?", arguments: [page.id.databaseText]) else {
                    return nil
                }
                return ResolvedDatabase(page: page, schema: try DatabaseSchema(row: row), catalog: try DatabaseCatalog.read(page.id, in: db))
            }
        }
    }

    public func property(_ text: String, in catalog: DatabaseCatalog) throws(ControlError) -> DatabaseProperty {
        try ViewJSON.property(["property": .string(text)], in: catalog)
    }

    public func option(_ text: String, of property: DatabaseProperty, in catalog: DatabaseCatalog) throws(ControlError) -> SelectOption {
        let options = (catalog.options[property.id] ?? []).filter { $0.deletedAt == nil }
        if let id = UUID(uuidString: text), let option = options.first(where: { $0.id == id }) { return option }
        let key = PagePath.normalized(text)
        if let option = options.first(where: { PagePath.normalized($0.name) == key }) { return option }
        throw ControlError(.optionNotFound, "У свойства «\(property.name)» нет варианта «\(text)»",
                           hint: "Варианты: " + options.map(\.name).joined(separator: ", "),
                           details: ["property": .string(property.name), "option": .string(text), "allowed": .array(options.map { .string($0.name) })])
    }

    /// Вид по id или имени; `nil` — первый вид базы.
    public func view(_ text: String?, ofDatabase databaseId: UUID) throws(ControlError) -> DatabaseView {
        let views = try read { try ViewQuery.views(of: databaseId, in: store) }
        guard let text else {
            guard let first = views.first else { throw ControlError(.viewNotFound, "У базы нет видов", hint: "Добавить: mynotion db view add") }
            return first
        }
        if let id = UUID(uuidString: text), let view = views.first(where: { $0.id == id }) { return view }
        let key = PagePath.normalized(text)
        let named = views.filter { PagePath.normalized($0.name) == key }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            throw ControlError(.viewNotFound, "Видов «\(text)» несколько (\(named.count)): укажите id", hint: "Виды: mynotion db view list",
                               details: ["candidates": .array(named.map { ["id": .string($0.id.controlText), "name": .string($0.name)] })])
        }
        throw ControlError(.viewNotFound, "Нет вида «\(text)»", hint: "Виды: mynotion db view list",
                           details: ["view": .string(text), "allowed": .array(views.map { .string($0.name) })])
    }

    /// Строка базы по id (или префиксу id от 8 знаков) или названию.
    public func row(_ text: String, inDatabase databaseId: UUID, includeTrashed: Bool = false) throws(ControlError) -> Page {
        let pointer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: pointer) {
            guard let page = try read({ try store.page(id) }), page.parentId == databaseId,
                  includeTrashed || page.trashedAt == nil else { throw rowNotFound(text) }
            return page
        }
        let idPrefix = PageLocator.isIdPrefix(pointer) ? pointer.lowercased() : nil
        let rows = try read { try PageQueries.children(of: databaseId, titled: pointer, idPrefix: idPrefix, in: store) }
            .filter { includeTrashed || $0.trashedAt == nil }
        var matches: [Page] = []
        if let idPrefix { matches = rows.filter { $0.id.controlText.hasPrefix(idPrefix) } }
        if matches.isEmpty {
            let key = PagePath.normalized(pointer)
            matches = rows.filter { PagePath.normalized($0.displayTitle) == key }
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw ControlError(.ambiguousPage, "Строк «\(text)» несколько (\(matches.count)): укажите id", hint: "Строки: mynotion db rows <база>",
                               details: ["candidates": .array(matches.prefix(PageLocator.candidateLimit).map {
                                   ["id": .string($0.id.controlText), "title": .string($0.title)]
                               })])
        }
        throw rowNotFound(text)
    }

    private func rowNotFound(_ text: String) -> ControlError {
        ControlError(.rowNotFound, "В базе нет строки «\(text)»", hint: "Строки: mynotion db rows <база>", details: ["row": .string(text)])
    }

    private func read<T>(_ body: () throws -> T) throws(ControlError) -> T {
        do {
            return try body()
        } catch {
            throw ControlError(.internal, "Не прочитать базу: \(error.localizedDescription)")
        }
    }
}

extension CommandSession {
    public var databaseRefs: DatabaseRefs { DatabaseRefs(store: host.store, pages: pageLocator) }

    /// База по аргументу `key` (`database` по умолчанию).
    public func database(_ key: String = "database") throws(ControlError) -> ResolvedDatabase {
        guard let text = string(key) else { throw CommandCatalog.missing(named: key, in: spec) }
        return try databaseRefs.database(text, includeTrashed: includeTrashed)
    }
}
