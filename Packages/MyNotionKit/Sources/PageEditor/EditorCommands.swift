import AppKit
import NotesCore

/// Оформление в строке, которое включается и выключается клавишами и меню «Формат».
public enum InlineFormat: Sendable, Hashable, CaseIterable {
    case bold
    case italic
    case strikethrough
    case code

    var style: InlineStyle {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .code: .code
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
    case toggleInline(InlineFormat)
    case setKind(BlockKind)
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
        case ("\r", [.command]), ("\u{3}", [.command]): return .toggleChecked
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

    /// Клавиши B, I, X, E на месте букв латинской раскладки.
    private static func latinLetter(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 11: "b"
        case 34: "i"
        case 7: "x"
        case 14: "e"
        default: nil
        }
    }
}
