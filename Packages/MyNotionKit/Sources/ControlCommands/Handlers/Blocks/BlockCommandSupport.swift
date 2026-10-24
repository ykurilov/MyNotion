import ControlProtocol
import Foundation
import NotesCore

/// Правила, общие для команд блоков.
enum BlockRules {
    /// Части колонок и таблиц: сами по себе их не двигают и не удаляют — только целым блоком (колонки, таблица).
    static let structural: Set<BlockKind> = [.column, .tableRow, .tableColumn, .tableCell]

    /// Виды, в которые блок превращается командой и из которых тоже: те, что меняются в окне пунктом «Превратить в».
    static let turnable: [BlockKind] = [
        .paragraph, .heading1, .heading2, .heading3, .quote, .bulletItem, .numberedItem, .checkbox, .toggle, .callout, .code, .equation,
    ]

    /// Блок можно двигать и удалять сам по себе.
    static func requireWholeBlock(_ block: Block, doing action: String) throws(ControlError) {
        guard structural.contains(block.kind) else { return }
        throw ControlError(.invalidArgument, "Блок вида «\(block.kind.rawValue)» — часть колонок или таблицы: его нельзя \(action) отдельно",
                           hint: "Работайте с целой таблицей или списком колонок", details: ["kind": .string(block.kind.rawValue)])
    }

    static func gone(_ id: UUID) -> ControlError {
        ControlError(.blockNotFound, "Блока \(id.controlText) уже нет на странице", details: ["block": .string(id.controlText)])
    }

    /// Поток блока в живом документе, место блока в нём и контейнер потока (`nil` — страница; сирота стоит в потоке страницы).
    @MainActor
    static func flow(of block: Block, in document: PageDocument) throws(ControlError) -> (blocks: [Block], index: Int, containerId: UUID?) {
        guard let current = document.block(block.id) else { throw gone(block.id) }
        let containerId = document.index(ofBlock: block.id) == nil ? current.containerId : nil
        let blocks = containerId.map(document.flow) ?? document.blocks
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { throw gone(block.id) }
        return (blocks, index, containerId)
    }
}

@MainActor
extension CommandSession {
    /// Чтение хранилища с ошибками команды.
    func blockStoreRead<T>(_ body: () throws -> T) throws(ControlError) -> T {
        do {
            return try body()
        } catch {
            throw ControlError.wrapping(error)
        }
    }

    /// Названия страниц для упоминаний в тексте блока.
    var mentionTitles: MentionTitles {
        { [store = host.store] id in
            guard let page = (try? store.page(id)) ?? nil else { return nil }
            return (page.displayTitle, page.icon)
        }
    }

    /// Страница блока, если её можно править: не в корзине (ни сама, ни через родителя).
    func editablePage(of block: Block) throws(ControlError) -> Page {
        try editablePage(block.pageId)
    }

    func editablePage(_ pageId: UUID) throws(ControlError) -> Page {
        let (page, index) = try blockStoreRead { () -> (Page?, PageIndex) in
            (try host.store.page(pageId), PageIndex(try host.store.pageOutline()))
        }
        guard let page else { throw ControlError.wrapping(NotesStoreError.pageNotFound(pageId)) }
        guard !index.isInTrash(page) else {
            throw ControlError(.pageInTrash, "Страница «\(page.displayTitle)» в корзине",
                               hint: "Вернуть: mynotion page restore \(page.id.controlText)", details: ["id": .string(page.id.controlText)])
        }
        return page
    }

    /// Блок, как он записан в базе (правка уже на диске), для ответа.
    func storedBlockJSON(_ id: UUID, extra: [String: ControlJSON] = [:]) throws(ControlError) -> ControlJSON {
        guard let block = try blockStoreRead({ try host.store.block(id) }) else {
            throw ControlError(.internal, "Блок \(id.controlText) не найден после записи")
        }
        var object: [String: ControlJSON] = ["block": BlockJSON.encode(block, titles: mentionTitles), "pageId": .string(block.pageId.controlText)]
        object.merge(extra) { _, new in new }
        return .object(object)
    }

    /// Страница в ответе: как в `page get`.
    func storedPageJSON(_ pageId: UUID) throws(ControlError) -> ControlJSON {
        let (page, index) = try blockStoreRead { () -> (Page?, PageIndex) in
            (try host.store.page(pageId), PageIndex(try host.store.pageOutline()))
        }
        guard let page else { throw ControlError.wrapping(NotesStoreError.pageNotFound(pageId)) }
        let path = (index.ancestors(of: page) + [page]).map(\.displayTitle)
        let hasChildren = index.pages.contains { $0.parentId == page.id && $0.trashedAt == nil }
        return PageJSON.encode(page, kind: .page, path: path, hasChildren: hasChildren, inTrash: index.isInTrash(page))
    }
}
