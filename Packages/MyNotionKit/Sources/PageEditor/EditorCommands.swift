import AppKit
import NotesCore

/// Оформление в строке, которое включается и выключается клавишами и меню «Формат».
public enum InlineFormat: Sendable, Hashable, CaseIterable {
    case bold
    case italic
    case strikethrough
    case code
    case underline

    var style: InlineStyle {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .code: .code
        case .underline: .underline
        }
    }
}

/// Действие редактора над блоками под курсором или выделением (contracts/editor-interactions.md, «Клавиши»).
public enum EditorCommand: Sendable, Hashable {
    case indent
    case outdent
    case moveBlocksUp
    case moveBlocksDown
    case toggleChecked
    /// ⌘⌥T: свернуть или раскрыть все переключатели страницы.
    case toggleAllCollapsed
    case toggleInline(InlineFormat)
    /// «Tx» панели форматирования: снять с выделения оформление, ссылки и цвета.
    case clearInlineFormatting
    case setKind(BlockKind)
    case applyColor(ColorChoice)
    case applyBlockColor(ColorChoice)
    case repeatLastColor
    /// ⌃⇧E: выделенный текст — формула в строке (у Notion ⌘⇧E, но здесь она занята выгрузкой).
    case insertInlineEquation
    /// ⌘D: копия блоков со всем вложенным сразу под ними, как у Notion.
    case duplicateBlocks
    /// ⇧⌘P: «Переместить в» для выделенных блоков (без выделенных блоков клавиша — у окна: переносит страницу).
    case moveBlocksToPage
}

/// Какие клавиши какое действие запускают. ⌘K свободна: ссылка — вставкой адреса или «Формат → Ссылка».
public enum EditorKeyBindings {
    public static func command(characters: String, modifiers: NSEvent.ModifierFlags) -> EditorCommand? {
        let modifiers = modifiers.intersection([.command, .option, .shift, .control])
        switch (characters.lowercased(), modifiers) {
        case ("b", [.command]): return .toggleInline(.bold)
        case ("i", [.command]): return .toggleInline(.italic)
        case ("x", [.command, .shift]): return .toggleInline(.strikethrough)
        case ("e", [.command]): return .toggleInline(.code)
        case ("e", [.control, .shift]): return .insertInlineEquation
        case ("u", [.command]): return .toggleInline(.underline)
        case ("h", [.command, .shift]): return .repeatLastColor
        case ("\r", [.command]), ("\u{3}", [.command]): return .toggleChecked
        case ("t", [.command, .option]): return .toggleAllCollapsed
        case ("d", [.command]): return .duplicateBlocks
        case ("p", [.command, .shift]): return .moveBlocksToPage
        case ("\u{F700}", [.option, .shift]): return .moveBlocksUp
        case ("\u{F701}", [.option, .shift]): return .moveBlocksDown
        default: return nil
        }
    }

    /// Shift+Enter (и Enter цифровой клавиатуры с Shift) — перенос строки внутри блока (FR-032).
    static func isLineBreak(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        return modifiers == [.shift] && ["\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "")
    }

    /// Клавиши события. В русской раскладке буквы берутся по месту клавиши, как у системных меню.
    static func command(for event: NSEvent) -> EditorCommand? {
        let characters = event.charactersIgnoringModifiers ?? ""
        if let command = command(characters: characters, modifiers: event.modifierFlags) { return command }
        guard let latin = latinLetter(forKeyCode: event.keyCode) else { return nil }
        return command(characters: latin, modifiers: event.modifierFlags)
    }

    /// Клавиши B, I, X, E, U, H, T, D, P на месте букв латинской раскладки.
    private static func latinLetter(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 11: "b"
        case 34: "i"
        case 7: "x"
        case 14: "e"
        case 32: "u"
        case 4: "h"
        case 17: "t"
        case 2: "d"
        case 35: "p"
        default: nil
        }
    }
}
