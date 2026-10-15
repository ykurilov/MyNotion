import AppKit
import NotesCore

/// Быстрые символы в начале строки (contracts/editor-interactions.md, «Быстрые символы»; FR-009).
public enum MarkdownShortcuts {
    /// Тип блока, в который превращается блок, если перед курсором ровно эти символы и нажат пробел.
    public static func kind(forTypedPrefix prefix: String) -> BlockKind? {
        switch prefix {
        case "#": .heading1
        case "##": .heading2
        case "###": .heading3
        case "-", "*": .bulletItem
        case "1.": .numberedItem
        case "[]", "[ ]": .checkbox
        default: nil
        }
    }

    /// Пункт, который Enter в пустом виде превращает в абзац.
    static func exitsOnEmptyEnter(_ kind: BlockKind) -> Bool {
        kind == .bulletItem || kind == .numberedItem || kind == .checkbox
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
        switch block.kind {
        case .paragraph:
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
