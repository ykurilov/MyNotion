import ControlProtocol
import Foundation
import NotesCore

/// Указатель страницы (research R10): id (регистр не важен, префикс от 8 знаков), `current` — страница передней
/// вкладки, путь из названий через `/` (без учёта регистра и `ё/е`, `\/` — косая черта в названии). Путь с `/` в
/// начале — от корня, без — где угодно (последние названия пути). Корзина видна только с `includeTrashed`.
@MainActor
public struct PageLocator {
    public static let currentKeyword = "current"
    public static let minimumIdPrefix = 8
    static let candidateLimit = 20

    let store: NotesStore
    let currentPageId: () -> UUID?

    public init(store: NotesStore, currentPageId: @escaping () -> UUID?) {
        self.store = store
        self.currentPageId = currentPageId
    }

    public func resolve(_ text: String, includeTrashed: Bool = false) throws(ControlError) -> Page {
        let pointer = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pointer.lowercased() == Self.currentKeyword {
            guard let id = currentPageId() else {
                throw ControlError(.pageNotFound, "Нет открытой страницы: «current» указывает на страницу передней вкладки",
                                   hint: "Укажите путь или id; дерево: mynotion page tree --depth 2")
            }
            return try byId(id, pointer: pointer, includeTrashed: includeTrashed)
        }
        if let id = UUID(uuidString: pointer) {
            return try byId(id, pointer: pointer, includeTrashed: includeTrashed)
        }

        if Self.isIdPrefix(pointer) {
            let index = PageIndex(try read { try store.pageOutline() })
            let prefix = pointer.lowercased()
            let matches = index.pages.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
            if !matches.isEmpty { return try pick(matches, pointer: pointer, index: index, includeTrashed: includeTrashed) }
        }

        let path = PagePath(pointer)
        guard let last = path.segments.last else {
            throw ControlError(.invalidValue, "Пустой указатель страницы", hint: "id, путь «Проекты/Встреча» или current")
        }
        // Только страницы с последним названием пути и их предки: полное дерево большой базы читается долго.
        let index = try read { try PageQueries.titled(last, in: store) }
        let matches = index.pages.filter { index.matches($0, path) }
        return try pick(matches, pointer: pointer, index: index, includeTrashed: includeTrashed)
    }

    private func byId(_ id: UUID, pointer: String, includeTrashed: Bool) throws(ControlError) -> Page {
        guard let page = try read({ try store.page(id) }) else { throw notFound(pointer) }
        if !includeTrashed, try isInTrash(page) { throw inTrash(page, pointer: pointer) }
        return page
    }

    private func pick(_ matches: [Page], pointer: String, index: PageIndex, includeTrashed: Bool) throws(ControlError) -> Page {
        let visible = includeTrashed ? matches : matches.filter { !index.isInTrash($0) }
        if visible.count == 1 { return visible[0] }
        if visible.count > 1 {
            let candidates = visible.prefix(Self.candidateLimit).map { page -> ControlJSON in
                ["id": .string(page.id.uuidString.lowercased()), "path": .string(index.path(of: page))]
            }
            throw ControlError(.ambiguousPage, "«\(pointer)» — несколько страниц (\(visible.count))",
                               hint: "Уточните путь от корня или укажите id одной из них",
                               details: ["candidates": .array(Array(candidates))])
        }
        if let trashed = matches.first { throw inTrash(trashed, pointer: pointer) }
        throw notFound(pointer)
    }

    private func isInTrash(_ page: Page) throws(ControlError) -> Bool {
        var current: Page? = page
        var seen: Set<UUID> = []
        while let page = current, seen.insert(page.id).inserted {
            if page.trashedAt != nil { return true }
            guard let parentId = page.parentId else { return false }
            current = try read { try store.page(parentId) }
        }
        return false
    }

    private func notFound(_ pointer: String) -> ControlError {
        ControlError(.pageNotFound, "Страница «\(pointer)» не найдена", hint: "Посмотрите дерево: mynotion page tree --depth 2",
                     details: ["page": .string(pointer)])
    }

    private func inTrash(_ page: Page, pointer: String) -> ControlError {
        ControlError(.pageInTrash, "Страница «\(pointer)» в корзине", hint: "Вернуть: mynotion page restore \(page.id.uuidString.lowercased()); найти в корзине — --include-trashed",
                     details: ["id": .string(page.id.uuidString.lowercased())])
    }

    static func isIdPrefix(_ text: String) -> Bool {
        text.count >= minimumIdPrefix && text.count < 36 && text.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    func read<T>(_ body: () throws -> T) throws(ControlError) -> T {
        do {
            return try body()
        } catch {
            throw ControlError(.internal, "Не прочитать страницы: \(error.localizedDescription)")
        }
    }
}

/// Путь из названий: `\/` — косая черта внутри названия; `/` в начале — от корня.
struct PagePath {
    let segments: [String]
    let fromRoot: Bool

    init(_ text: String) {
        var segments: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "/" {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        segments.append(current)
        fromRoot = text.hasPrefix("/")
        self.segments = segments.map(Self.normalized).filter { !$0.isEmpty }
    }

    /// Сравнение названий: без регистра, `ё` = `е`, без пробелов по краям.
    static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    /// Название в пути ответа: `/` внутри экранирован.
    static func escaped(_ title: String) -> String {
        title.replacingOccurrences(of: "/", with: "\\/")
    }
}

/// Страницы по id: родители, путь, корзина.
struct PageIndex {
    let pages: [Page]
    let byId: [UUID: Page]

    init(_ pages: [Page]) {
        self.pages = pages
        byId = Dictionary(pages.map { ($0.id, $0) }) { first, _ in first }
    }

    func matches(_ page: Page, _ path: PagePath) -> Bool {
        var current: Page? = page
        for segment in path.segments.reversed() {
            guard let candidate = current, PagePath.normalized(candidate.displayTitle) == segment else { return false }
            current = candidate.parentId.flatMap { byId[$0] }
        }
        return !path.fromRoot || current == nil
    }

    func ancestors(of page: Page) -> [Page] {
        var chain: [Page] = []
        var seen: Set<UUID> = [page.id]
        var current = page.parentId.flatMap { byId[$0] }
        while let parent = current, seen.insert(parent.id).inserted {
            chain.append(parent)
            current = parent.parentId.flatMap { byId[$0] }
        }
        return chain.reversed()
    }

    func isInTrash(_ page: Page) -> Bool {
        page.trashedAt != nil || ancestors(of: page).contains { $0.trashedAt != nil }
    }

    /// Путь от корня: `Проекты/Встреча`.
    func path(of page: Page) -> String {
        (ancestors(of: page) + [page]).map { PagePath.escaped($0.displayTitle) }.joined(separator: "/")
    }
}
