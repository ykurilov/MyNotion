import ControlProtocol
import Foundation
import NotesCore
import PageSearch

/// Поиск, избранное, недавние, шаблоны, история, вложения — этап 5 005 (US4). Каждая команда — та же операция, что кнопка
/// окна: поиск ⌘P, звёздочка, «Сделать шаблоном». История — `HistoryHandlers`, вложения — `AttachmentHandlers`.
public enum LibraryHandlers {
    public static let all: [String: CommandHandler] = [
        "search": search,
        "favorites.list": favoritesList, "favorites.add": favoritesAdd, "favorites.remove": favoritesRemove, "favorites.move": favoritesMove,
        "recents": recents,
        "template.list": templateList, "template.mark": templateMark, "template.unmark": templateUnmark,
    ].merging(HistoryHandlers.all) { first, _ in first }.merging(AttachmentHandlers.all) { first, _ in first }

    /// Недавних в списке «Показать все» окна.
    static let recentsLimit = 50

    // MARK: Поиск

    /// Выдача поиска окна: то же дерево (без корзины), тот же порядок — сначала названия, потом текст.
    static let search: CommandHandler = { session in
        let store = session.host.store
        let results = try PageSearch(store: store).results(for: session.string("query") ?? "", in: store.pageTree(),
                                                           limit: session.int("limit") ?? PageSearch.defaultLimit)
        let outline = try PageOutline(store: store)
        let items: [ControlJSON] = results.map { result in
            let title = result.title.isEmpty ? Page.untitledTitle : result.title
            return [
                "id": .string(result.pageId.controlText), "title": .string(title), "icon": result.icon.map(ControlJSON.string) ?? .null,
                "path": .array((result.path + [title]).map(ControlJSON.string)),
                "kind": .string((outline.page(result.pageId).map(outline.kind) ?? .page).rawValue),
                "snippet": result.snippet.map { .string($0.text) } ?? .null,
                "blockId": result.blockId.map { .string($0.controlText) } ?? .null,
            ]
        }
        return CommandResult(["items": .array(items), "nextCursor": .null], text: "Найдено: \(items.count)")
    }

    // MARK: Избранное и недавние

    static let favoritesList: CommandHandler = { session in
        let outline = try PageOutline(store: session.host.store)
        let pages = try session.host.store.favoritePages()
        return CommandResult(try session.paged(pages.map(outline.json)), text: "\(pages.count) в избранном")
    }

    static let favoritesAdd: CommandHandler = { session in
        let page = try session.page()
        try session.pageTree.addToFavorites(page.id)
        return try session.pageResult(page.id)
    }

    static let favoritesRemove: CommandHandler = { session in
        let page = try session.page()
        try session.pageTree.removeFromFavorites(page.id)
        return try session.pageResult(page.id)
    }

    static let favoritesMove: CommandHandler = { session in
        let page = try session.page()
        guard page.favorite != nil else {
            throw ControlError(.invalidValue, "«\(page.title)» нет в избранном", hint: "Добавить: mynotion favorites add \(page.id.controlText)",
                               details: ["page": .string(page.id.controlText)])
        }
        try session.pageTree.moveFavorite(page.id, toIndex: session.int("index") ?? 0)
        return try session.pageResult(page.id)
    }

    /// Недавние панели: свежие сверху, без корзины и шаблонов.
    static let recents: CommandHandler = { session in
        let outline = try PageOutline(store: session.host.store)
        let pages = try session.host.store.recentPages(limit: session.int("limit") ?? recentsLimit)
        let items: [ControlJSON] = pages.map { page in
            var object = outline.json(page).object ?? [:]
            object["visitedAt"] = page.visitedAt.map { .string($0.controlText) } ?? .null
            return .object(object)
        }
        return CommandResult(["items": .array(items), "nextCursor": .null], text: "\(items.count) недавних")
    }

    // MARK: Шаблоны

    static let templateList: CommandHandler = { session in
        let outline = try PageOutline(store: session.host.store)
        let templates = try session.host.store.pageTree().templates
        return CommandResult(try session.paged(templates.map(outline.json)), text: "\(templates.count) шаблонов")
    }

    /// Как «Сделать шаблоном»: страница с веткой уходит в корень и получает отметку.
    static let templateMark: CommandHandler = { session in
        let page = try session.page()
        let outline = try PageOutline(store: session.host.store)
        guard outline.kind(of: page) != .row else {
            throw ControlError(.invalidValue, "«\(page.title)» — строка базы: у баз свои шаблоны строк", hint: "mynotion db template list <база>",
                               details: ["page": .string(page.id.controlText)])
        }
        try session.pageTree.makeTemplate(page.id)
        return try session.pageResult(page.id)
    }

    static let templateUnmark: CommandHandler = { session in
        let page = try session.page()
        try session.pageTree.stopBeingTemplate(page.id)
        return try session.pageResult(page.id)
    }
}

// MARK: - Файлы на диске

extension CommandSession {
    /// Путь из аргумента: `~` — домашняя папка, относительный — от папки, где запущена команда.
    func diskURL(_ key: String) throws(ControlError) -> URL {
        guard let text = string(key) else { throw CommandCatalog.missing(named: key, in: spec) }
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        let base = URL(fileURLWithPath: request.cwd ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    /// Существующий файл (не папка) по аргументу.
    func existingFile(_ key: String) throws(ControlError) -> URL {
        let url = try diskURL(key)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ControlError(.fileNotFound, "Нет файла «\(url.path)»", hint: "Путь — от папки, где запущена команда, или полный",
                               details: ["argument": .string(key), "path": .string(url.path)])
        }
        return url
    }
}
