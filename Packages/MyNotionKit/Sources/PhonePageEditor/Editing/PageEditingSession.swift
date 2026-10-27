import Foundation
import NotesCore

/// Куда поставить курсор после правки: блок и место в его тексте (UTF-16).
struct CaretTarget: Hashable {
    var blockId: UUID
    var offset: Int
}

/// Что сделал ⌫ в начале блока.
enum BackspaceOutcome: Hashable {
    /// Ничего: блок выше без текста, а этот не пустой.
    case unchanged
    case caret(CaretTarget)
    /// Курсор — в конец названия страницы.
    case title
}

/// Правила правки страницы на iPhone поверх общего `PageDocument` (без UIKit): Enter, ⌫ в начале блока, чекбокс,
/// свёрнутые переключатели. Поведение — как у редактора Mac (`MarkdownShortcuts`, `PageTextStorageMapper`)
/// и Notion. Правки идут через `replaceBlocks` документа: свойства и цвет блока, которых iPhone не знает, остаются.
@MainActor
final class PageEditingSession {
    let document: PageDocument
    private let viewState: BlockViewStateStore?
    /// Свёрнутые переключатели страницы на этом устройстве (как на Mac — мимо синхронизации).
    private(set) var collapsedBlockIds: Set<UUID>

    init(document: PageDocument, viewState: BlockViewStateStore?) {
        self.document = document
        self.viewState = viewState
        collapsedBlockIds = (try? viewState?.collapsedBlockIds(ofPage: document.pageId)) ?? []
    }

    func rows() -> [PageRow] {
        PageRows.make(document.blocks, collapsed: collapsedBlockIds)
    }

    // MARK: Текст

    func setText(_ text: InlineText, ofBlock id: UUID) {
        document.setText(text, ofBlock: id)
    }

    func setTitle(_ title: String) {
        document.setTitle(title, origin: self)
    }

    // MARK: Enter

    /// Enter в блоке `id` с выделением `selection`. Возвращает, где продолжить набор.
    func pressReturn(inBlock id: UUID, selection: NSRange) -> CaretTarget? {
        guard let index = document.index(ofBlock: id) else { return nil }
        var block = document.blocks[index]
        guard BlockLook(block.kind).isEditableText else { return nil }
        if selection.length > 0 {
            let (head, rest) = block.text.split(at: selection.location)
            block.text = head.appending(rest.split(at: selection.length).tail)
        }
        let offset = min(selection.location, block.text.utf16Count)

        if block.text.string.isEmpty {
            // Пустой пункт, чекбокс, переключатель — выход из списка; пустой вложенный абзац — на уровень выше.
            if MarkdownRules.exitsOnEmptyReturn(block.kind) {
                update(block) { draft in
                    draft.kind = .paragraph
                    draft.indent = 0
                }
                return CaretTarget(blockId: id, offset: 0)
            }
            if block.kind == .paragraph, block.indent > 0 {
                update(block) { $0.indent -= 1 }
                return CaretTarget(blockId: id, offset: 0)
            }
        }

        let newKind = MarkdownRules.kindAfterSplit(block.kind)
        if offset == 0, !block.text.string.isEmpty {
            // Enter в начале непустого блока: сверху — пустой блок, текст остаётся в своём.
            let above = BlockDraft(id: nil, kind: newKind, indent: block.indent)
            replace(from: index, to: index, with: [above, draft(of: block)])
            return CaretTarget(blockId: id, offset: 0)
        }

        let (head, tail) = block.text.split(at: offset)
        var current = draft(of: block)
        current.text = head
        let isCollapsedToggle = block.kind == .toggle && collapsedBlockIds.contains(id)
        let indents = BlockNesting.displayIndents(document.blocks)
        let hasChildren = index + 1 < indents.count && indents[index + 1] > indents[index]
        var next = BlockDraft(id: nil, kind: newKind, text: tail, indent: block.indent)
        if isCollapsedToggle {
            // Свёрнутый переключатель: новый — после всего, что в нём спрятано.
            setTextIfChanged(head, of: block)
            let end = PageRows.subtreeEnd(ofBlockAt: index, in: document.blocks)
            let ids = document.replaceBlocks(after: document.blocks[end].id, before: blockId(at: end + 1), with: [next], origin: self)
            return ids.first.map { CaretTarget(blockId: $0, offset: 0) }
        }
        if block.kind == .toggle, hasChildren {
            // Раскрытый переключатель с детьми: новый блок — его первый ребёнок, как в Notion.
            next = BlockDraft(id: nil, kind: .paragraph, text: tail, indent: block.indent + 1)
        }
        let ids = replace(from: index, to: index, with: [current, next])
        return ids.last.map { CaretTarget(blockId: $0, offset: 0) }
    }

    // MARK: ⌫ в начале блока

    func pressBackspaceAtStart(ofBlock id: UUID) -> BackspaceOutcome {
        guard let index = document.index(ofBlock: id) else { return .unchanged }
        let block = document.blocks[index]
        guard BlockLook(block.kind).isEditableText else { return .unchanged }
        if block.kind != .paragraph {
            update(block) { draft in
                draft.kind = .paragraph
                draft.isChecked = false
            }
            return .caret(CaretTarget(blockId: id, offset: 0))
        }
        if block.indent > 0 {
            let shown = BlockNesting.displayIndents(document.blocks)[index]
            update(block) { $0.indent = max(shown - 1, 0) }
            return .caret(CaretTarget(blockId: id, offset: 0))
        }

        let rows = rows()
        guard let rowIndex = rows.firstIndex(where: { $0.block.id == id }), rowIndex > 0 else {
            guard block.text.string.isEmpty, document.blocks.count > 1 else { return block.text.string.isEmpty ? .title : .unchanged }
            remove(block)
            return .title
        }
        let previous = rows[rowIndex - 1].block
        if BlockLook(previous.kind).isEditableText {
            let merged = previous.text.appending(block.text)
            remove(block)
            document.setText(merged, ofBlock: previous.id)
            return .caret(CaretTarget(blockId: previous.id, offset: previous.text.utf16Count))
        }
        // Блок выше без своего текста (разделитель, картинка, подстраница): его не трогаем, пустой абзац просто уходит.
        guard block.text.string.isEmpty else { return .unchanged }
        remove(block)
        if let editable = rows[..<rowIndex].last(where: { $0.look.isEditableText }) {
            return .caret(CaretTarget(blockId: editable.block.id, offset: editable.block.text.utf16Count))
        }
        return .title
    }

    // MARK: Касания

    func toggleChecked(_ id: UUID) {
        guard let block = document.block(id), block.kind == .checkbox, document.index(ofBlock: id) != nil else { return }
        update(block) { $0.isChecked.toggle() }
    }

    func setCollapsed(_ collapsed: Bool, toggle id: UUID) {
        if collapsed { collapsedBlockIds.insert(id) } else { collapsedBlockIds.remove(id) }
        try? viewState?.setCollapsed(collapsed, blockId: id)
    }

    /// Enter в названии: курсор в первый блок, если в нём можно писать, иначе сверху — новый абзац.
    func returnFromTitle() -> CaretTarget {
        if let first = document.blocks.first, BlockLook(first.kind).isEditableText {
            return CaretTarget(blockId: first.id, offset: 0)
        }
        let ids = document.replaceBlocks(after: nil, before: document.blocks.first?.id, with: [BlockDraft(id: nil)], origin: self)
        return CaretTarget(blockId: ids[0], offset: 0)
    }

    /// Касание пустого места под страницей: в последний пустой абзац, иначе — новый абзац в конце.
    func tapBelowLastBlock() -> CaretTarget {
        if let last = rows().last?.block, last.kind == .paragraph, last.text.string.isEmpty {
            return CaretTarget(blockId: last.id, offset: 0)
        }
        let ids = document.replaceBlocks(after: document.blocks.last?.id, before: nil, with: [BlockDraft(id: nil)], origin: self)
        return CaretTarget(blockId: ids[0], offset: 0)
    }

    // MARK: Внутреннее

    private func draft(of block: Block) -> BlockDraft {
        BlockDraft(block)
    }

    private func blockId(at index: Int) -> UUID? {
        document.blocks.indices.contains(index) ? document.blocks[index].id : nil
    }

    /// Заменить блоки с `from` по `to` включительно черновиками.
    @discardableResult
    private func replace(from: Int, to: Int, with drafts: [BlockDraft]) -> [UUID] {
        document.replaceBlocks(after: blockId(at: from - 1), before: blockId(at: to + 1), with: drafts, origin: self)
    }

    private func update(_ block: Block, _ change: (inout BlockDraft) -> Void) {
        guard let index = document.index(ofBlock: block.id) else { return }
        var draft = draft(of: block)
        change(&draft)
        replace(from: index, to: index, with: [draft])
    }

    private func setTextIfChanged(_ text: InlineText, of block: Block) {
        if text != block.text.normalized() { document.setText(text, ofBlock: block.id) }
    }

    private func remove(_ block: Block) {
        guard let index = document.index(ofBlock: block.id) else { return }
        replace(from: index, to: index, with: [])
    }
}

/// Правила Enter по типам — те же, что у описателей типов редактора Mac (`BlockKinds/`).
enum MarkdownRules {
    /// Новый блок после Enter: абзац, пункт, чекбокс и переключатель продолжаются, остальные — абзацем.
    static func kindAfterSplit(_ kind: BlockKind) -> BlockKind {
        switch kind {
        case .paragraph, .bulletItem, .numberedItem, .checkbox, .toggle: kind
        default: .paragraph
        }
    }

    /// Enter в пустом пункте списка, чекбоксе или переключателе превращает его в абзац.
    static func exitsOnEmptyReturn(_ kind: BlockKind) -> Bool {
        switch kind {
        case .bulletItem, .numberedItem, .checkbox, .toggle: true
        default: false
        }
    }
}
