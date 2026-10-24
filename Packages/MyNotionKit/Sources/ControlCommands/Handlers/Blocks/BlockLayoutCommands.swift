import ControlProtocol
import Foundation
import NotesCore

/// Где стоит блок: `block move`, `indent`, `outdent`, `delete`, `move-to-page`. Правила — те же, что у окна
/// (`BlockStructure`): вложенные блоки едут и удаляются вместе с блоком.
enum BlockLayoutCommands {
    static let move: CommandHandler = { session in
        let block = try session.block()
        try BlockRules.requireWholeBlock(block, doing: "переставить")
        let page = try session.editablePage(of: block)
        let target = try BlockTarget.from(session, page: page)
        try await BlockPageEditor(session: session, pageId: page.id).edit("Перенос блока") { document in
            let (flow, index, _) = try BlockRules.flow(of: block, in: document)
            let moved = flow[index..<BlockStructure.subtreeEnd(flow, of: index)]
            let movedIds = Set(moved.map(\.id))
            if let anchor = target.anchor, movedIds.contains(anchor.id) {
                throw ControlError(.invalidArgument, "Нельзя поставить блок за самим собой или за его вложенными блоками",
                                   hint: "Выберите другой блок в --after", details: ["argument": "after"])
            }
            let placement = try target.place(in: document, excluding: movedIds, kind: block.kind)
            document.apply(document.changesMoving(moved.map(\.id), to: placement.containerId, after: placement.after,
                                                  before: placement.before, rootIndent: placement.indent))
        }
        return CommandResult(try session.storedBlockJSON(block.id), text: "✓ Блок перенесён")
    }

    static let indent: CommandHandler = { session in try await shift(session, delta: 1) }
    static let outdent: CommandHandler = { session in try await shift(session, delta: -1) }

    /// Tab и ⇧Tab из окна: блок вкладывается не глубже соседа сверху + 1, вложенные едут с ним.
    @MainActor
    private static func shift(_ session: CommandSession, delta: Int) async throws -> CommandResult {
        let block = try session.block()
        try BlockRules.requireWholeBlock(block, doing: "сдвинуть")
        let pageId = try session.editablePage(of: block).id
        let changed = try await BlockPageEditor(session: session, pageId: pageId).edit(delta > 0 ? "Отступ вправо" : "Отступ влево") { document in
            let (flow, index, containerId) = try BlockRules.flow(of: block, in: document)
            guard let change = BlockStructure.indenting(flow, selected: index..<(index + 1), delta: delta) else { return false }
            let range = change.range
            document.replaceBlocks(in: containerId, after: range.lowerBound > 0 ? flow[range.lowerBound - 1].id : nil,
                                   before: range.upperBound < flow.count ? flow[range.upperBound].id : nil, with: change.drafts)
            return true
        }
        let text = changed ? "✓ Отступ изменён" : "Отступ не изменился: так глубже или мельче нельзя"
        return CommandResult(try session.storedBlockJSON(block.id, extra: ["changed": .bool(changed)]), text: text)
    }

    static let delete: CommandHandler = { session in
        let block = try session.block()
        try BlockRules.requireWholeBlock(block, doing: "удалить")
        let pageId = try session.editablePage(of: block).id
        let deleted = try await BlockPageEditor(session: session, pageId: pageId).edit("Удаление блока") { document -> [UUID] in
            let (flow, index, containerId) = try BlockRules.flow(of: block, in: document)
            let end = BlockStructure.subtreeEnd(flow, of: index)
            // На странице и в колонке не остаётся пустого места: последний блок заменяется пустым абзацем.
            let leavesNothing = index == 0 && end == flow.count
            let replacement = leavesNothing && (containerId == nil || document.block(containerId!)?.kind == .column)
                ? [BlockDraft(id: nil)] : []
            document.replaceBlocks(in: containerId, after: index > 0 ? flow[index - 1].id : nil,
                                   before: end < flow.count ? flow[end].id : nil, with: replacement)
            return flow[index..<end].map(\.id)
        }
        return CommandResult(["deleted": .array(deleted.map { .string($0.controlText) }), "pageId": .string(pageId.controlText)],
                             text: "✓ Удалено блоков: \(deleted.count)")
    }

    static let moveToPage: CommandHandler = { session in
        let block = try session.block()
        try BlockRules.requireWholeBlock(block, doing: "перенести")
        let source = try session.editablePage(of: block)
        let target = try session.page()
        guard target.id != source.id else {
            throw ControlError(.invalidArgument, "Блок уже на странице «\(target.displayTitle)»",
                               hint: "Внутри страницы блок двигает mynotion block move", details: ["argument": "page"])
        }
        try await session.willWrite(source.id)
        try await session.willWrite(target.id)
        let host = session.host
        guard host.openDocuments.saveAll() else {
            throw ControlError(.internal, "Не удалось записать страницу на диск", hint: "Проверьте свободное место и повторите команду")
        }
        let known = try session.blockStoreRead { Set(try host.store.pageContent(target.id)?.blocks.map(\.id) ?? []) }
        do {
            try session.pageTree.moveBlocks([block.id], from: source.id, to: target.id)
        } catch {
            throw ControlError.wrapping(error)
        }
        // Копии на странице-цели: новые блоки её потока по порядку. Окна обеих страниц перечитывают их.
        let arrived = try session.blockStoreRead {
            BlockSnapshot.flow(try host.store.pageContent(target.id)?.blocks ?? [], of: nil).filter { !known.contains($0.id) }
        }
        session.touch([source.id, target.id])
        host.refreshAfterDirectWrite(pages: [source.id, target.id])
        return CommandResult(["moved": .array(arrived.map { .string($0.id.controlText) }), "pageId": .string(target.id.controlText),
                              "fromPageId": .string(source.id.controlText)],
                             text: "✓ Перенесено блоков: \(arrived.count) → «\(target.displayTitle)»")
    }
}

/// `block check`, `uncheck`, `expand`, `collapse`: отметка задачи и раскрытие переключателя.
enum BlockStateCommands {
    static let check: CommandHandler = { session in try await setChecked(session, true) }
    static let uncheck: CommandHandler = { session in try await setChecked(session, false) }

    @MainActor
    private static func setChecked(_ session: CommandSession, _ checked: Bool) async throws -> CommandResult {
        let block = try session.block()
        guard block.kind == .checkbox else {
            throw ControlError(.invalidArgument, "Отметить можно только задачу (checkbox), а это «\(block.kind.rawValue)»",
                               hint: "Превратить блок в задачу: mynotion block update <id> --kind checkbox",
                               details: ["kind": .string(block.kind.rawValue)])
        }
        let pageId = try session.editablePage(of: block).id
        try await BlockPageEditor(session: session, pageId: pageId).edit(checked ? "Отметка задачи" : "Снятие отметки") { document in
            guard var current = document.block(block.id) else { throw BlockRules.gone(block.id) }
            current.isChecked = checked
            document.apply(BlockChanges(upserts: [current]))
        }
        return CommandResult(try session.storedBlockJSON(block.id), text: checked ? "✓ Задача отмечена" : "✓ Отметка снята")
    }

    static let expand: CommandHandler = { session in try setCollapsed(session, false) }
    static let collapse: CommandHandler = { session in try setCollapsed(session, true) }

    /// Свёрнутость хранится на этом Mac и не пишется в страницу: ни отмены, ни синхронизации (data-model.md, «BlockViewState»).
    @MainActor
    private static func setCollapsed(_ session: CommandSession, _ collapsed: Bool) throws -> CommandResult {
        let block = try session.block()
        guard block.kind == .toggle else {
            throw ControlError(.invalidArgument, "Раскрывать и сворачивать можно только раскрывающийся список (toggle), а это «\(block.kind.rawValue)»",
                               details: ["kind": .string(block.kind.rawValue)])
        }
        try session.blockStoreRead { try BlockViewStateStore(database: session.host.store.database).setCollapsed(collapsed, blockId: block.id) }
        return CommandResult(try session.storedBlockJSON(block.id, extra: ["collapsed": .bool(collapsed)]),
                             text: collapsed ? "✓ Список свёрнут" : "✓ Список раскрыт")
    }
}
