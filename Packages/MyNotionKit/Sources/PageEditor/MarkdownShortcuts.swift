import AppKit
import NotesCore

/// Быстрые символы в начале строки (contracts/editor-interactions.md, «Быстрые символы»; FR-009).
public enum MarkdownShortcuts {
    /// Тип блока, в который превращается блок, если перед курсором ровно эти символы и нажат пробел.
    /// Символы — из описателей типов (`BlockKinds/`).
    public static func kind(forTypedPrefix prefix: String) -> BlockKind? {
        BlockKindRegistry.shortcutKinds[prefix]
    }

    /// Пункт, который Enter в пустом виде превращает в абзац.
    static func exitsOnEmptyEnter(_ kind: BlockKind) -> Bool {
        kind.descriptor.exitsOnEmptyEnter
    }
}

extension PageTextView {
    /// Пробел после быстрых символов в начале любого блока, как в Notion: символы убираются, блок меняет тип,
    /// вложенность остаётся (у заголовков её нет). Одно действие для ⌘Z.
    func applyMarkdownShortcut() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location) else { return false }
        let block = document.blocks[position.index]
        guard block.kind != .pageLink, position.offset > 0 else { return false }
        let prefix = (block.text.string as NSString).substring(to: min(position.offset, (block.text.string as NSString).length))
        guard let kind = MarkdownShortcuts.kind(forTypedPrefix: prefix) else { return false }

        breakUndoCoalescing()
        let prefixRange = NSRange(location: selection.location - position.offset, length: position.offset)
        guard replaceText(in: prefixRange, with: "") else { return false }
        setKind(kind, ofBlocksAt: position.index..<position.index + 1)
        return true
    }

    /// ⌫ в начале блока: не-абзац становится абзацем, абзац склеивается с блоком выше.
    func handleBackspaceAtBlockStart() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location), position.offset == 0 else { return false }
        let block = document.blocks[position.index]
        // Блок над курсором без своего текста: ⌫ выделяет его целиком, а не склеивает текст с его знаком-вложением.
        if position.index > 0, document.blocks[position.index - 1].kind.rendersAsAttachment, !block.kind.rendersAsAttachment {
            if block.kind == .paragraph || block.kind == .pageLink {
                selectBlocks(position.index - 1..<position.index)
                return true
            }
        }
        switch block.kind {
        case .paragraph:
            // Пустой первый абзац убирается, а курсор уходит в конец названия страницы (на странице остаётся хоть один блок).
            if position.index == 0, block.text.string.isEmpty {
                if document.blocks.count > 1 { removeBlocks(at: 0..<1) }
                header.focusTitle()
                return true
            }
            // Блок-подстраницу текстом не склеиваем: у неё текста нет. Пустой абзац под ней просто убирается.
            guard position.index > 0, document.blocks[position.index - 1].kind == .pageLink else { return false }
            if block.text.string.isEmpty {
                removeBlocks(at: position.index..<position.index + 1)
            }
            return true
        case .pageLink:
            // Ссылку на страницу ⌫ не ломает: курсор уходит в конец блока выше. Убрать её — меню «⋮⋮».
            if position.index > 0 { setSelectedRange(NSRange(location: selection.location - 1, length: 0)) }
            return true
        default:
            setKind(.paragraph, ofBlocksAt: position.index..<position.index + 1)
            return true
        }
    }

    /// Enter в пустом пункте списка или чекбоксе — выход из списка: блок становится абзацем без вложенности.
    func handleNewlineInEmptyItem() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, let position = mapper.blockPosition(at: selection.location) else { return false }
        let block = document.blocks[position.index]
        guard MarkdownShortcuts.exitsOnEmptyEnter(block.kind), block.text.string.isEmpty else { return false }
        var draft = BlockDraft(block)
        draft.kind = .paragraph
        draft.indent = 0
        changeBlocks(position.index..<position.index + 1, to: [draft], actionName: "Тип блока")
        return true
    }
}
