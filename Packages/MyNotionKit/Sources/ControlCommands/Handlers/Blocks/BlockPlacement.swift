import ControlProtocol
import Foundation
import NotesCore

/// Куда встанет блок: поток (`nil` — страница), соседи в нём и глубина самого блока.
struct BlockPlacement {
    var containerId: UUID?
    var after: UUID?
    var before: UUID?
    var indent: Int
}

/// Место из аргументов `--first`, `--last`, `--after`, `--inside`. Блоки-указатели проверены до правки страницы, а соседи
/// считаются по живому документу: пока команда ждала своей очереди, страница могла измениться.
@MainActor
enum BlockTarget {
    case first
    case last
    case after(Block)
    case inside(Block)

    static func from(_ session: CommandSession, page: Page) throws(ControlError) -> BlockTarget {
        if session.flag("first") { return .first }
        if session.args["after"] != nil {
            let anchor = try session.block("after", inPage: page.id)
            try BlockRules.requireWholeBlock(anchor, doing: "взять опорой")
            return .after(anchor)
        }
        if session.args["inside"] != nil {
            let parent = try session.block("inside", inPage: page.id)
            guard parent.kind == .column || parent.kind.canHaveChildren else {
                throw ControlError(.invalidArgument, "Нельзя вставить внутрь блока вида «\(parent.kind.rawValue)»",
                                   hint: "Внутрь можно: пункт списка, задачу, раскрывающийся список (toggle), выноску, цитату, колонку",
                                   details: ["argument": "inside", "kind": .string(parent.kind.rawValue)])
            }
            return .inside(parent)
        }
        return .last
    }

    /// Блок, за которым встаёт новый (для `--after`): с ним нельзя ставить блок рядом с самим собой.
    var anchor: Block? {
        if case .after(let block) = self { return block }
        return nil
    }

    /// Соседи по живому документу. `moved` — блоки, которые сейчас уедут: их в потоке как будто нет. Заголовок встаёт
    /// на самую глубокую допустимую глубину (как Tab в окне).
    func place(in document: PageDocument, excluding moved: Set<UUID> = [], kind: BlockKind) throws(ControlError) -> BlockPlacement {
        func flow(_ containerId: UUID?) -> [Block] { containerId.map(document.flow) ?? document.blocks }

        func neighbours(_ blocks: [Block], at end: Int, container: UUID?, indent: Int) -> BlockPlacement {
            let above = blocks[..<end].filter { !moved.contains($0.id) }
            let below = blocks[end...].first { !moved.contains($0.id) }
            let depth = kind.isHeading ? BlockStructure.headingIndent(indent, under: above.map { ($0.indent, $0.kind) }) : indent
            return BlockPlacement(containerId: container, after: above.last?.id, before: below?.id, indent: depth)
        }

        func end(ofSubtreeOf block: Block, in blocks: [Block]) throws(ControlError) -> Int {
            guard let index = blocks.firstIndex(where: { $0.id == block.id }) else {
                throw ControlError(.blockNotFound, "Блока \(block.id.controlText) уже нет на странице")
            }
            return BlockStructure.subtreeEnd(blocks, of: index)
        }

        switch self {
        case .first:
            return neighbours(flow(nil), at: 0, container: nil, indent: 0)
        case .last:
            let blocks = flow(nil)
            return neighbours(blocks, at: blocks.count, container: nil, indent: 0)
        case .after(let anchor):
            let blocks = flow(anchor.containerId)
            return neighbours(blocks, at: try end(ofSubtreeOf: anchor, in: blocks), container: anchor.containerId, indent: anchor.indent)
        case .inside(let parent):
            if parent.kind == .column {
                let blocks = flow(parent.id)
                return neighbours(blocks, at: blocks.count, container: parent.id, indent: 0)
            }
            let indent = parent.indent + 1
            guard Block.indentRange.contains(indent) else {
                throw ControlError(.invalidArgument, "Глубже \(Block.indentRange.upperBound) уровней блоки не вкладываются",
                                   details: ["argument": "inside"])
            }
            let blocks = flow(parent.containerId)
            return neighbours(blocks, at: try end(ofSubtreeOf: parent, in: blocks), container: parent.containerId, indent: indent)
        }
    }
}
