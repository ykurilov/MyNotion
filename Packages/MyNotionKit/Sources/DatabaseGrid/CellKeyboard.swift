import AppKit

/// Клавиша, которую сетка различает.
public enum CellKey: Sendable, Hashable {
    case arrow(CellMove)
    case tab, enter, escape, delete, forwardDelete
    /// Печатный знак (`characters` события).
    case character

    /// Клавиша события AppKit; печатный знак — `.character`.
    public init?(event: NSEvent) {
        switch event.keyCode {
        case 123: self = .arrow(.left)
        case 124: self = .arrow(.right)
        case 125: self = .arrow(.down)
        case 126: self = .arrow(.up)
        case 48: self = .tab
        case 36, 76: self = .enter
        case 53: self = .escape
        case 51: self = .delete
        case 117: self = .forwardDelete
        default:
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
            self = .character
        }
    }
}

/// Модификаторы, которые сетка различает.
public struct CellModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = CellModifiers(rawValue: 1)
    public static let command = CellModifiers(rawValue: 2)
    public static let option = CellModifiers(rawValue: 4)
    public static let control = CellModifiers(rawValue: 8)

    public init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: CellModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }
}

/// Что сделать по клавише (contracts/database-ui.md, «Ячейки и клавиши»).
public enum CellCommand: Sendable, Hashable {
    case move(CellMove, extending: Bool)
    /// Правка выбранной ячейки; с буквой — содержимое заменяется ею.
    case beginEditing(replacingWith: String?)
    /// Закончить правку (значение записывается) и шагнуть; `nil` — остаться на ячейке.
    case commit(then: CellMove?)
    /// Esc на выбранной ячейке: выбрана строка.
    case selectRow
    case selectAll, copy, cut, paste, erase
    /// ⇧⌘↩ — строка в новой вкладке.
    case openInNewTab
    /// ⌘D — дублировать строку (меню строки).
    case duplicateRows
    /// Клавиша не для сетки (⌘Z и меню — дальше по цепочке).
    case none
}

/// Клавиши сетки и правки ячейки.
public enum CellKeyboard {
    public static func command(for key: CellKey, modifiers: CellModifiers, characters: String?, isEditing: Bool) -> CellCommand {
        if isEditing {
            switch key {
            case .enter where modifiers.isEmpty: return .commit(then: .down)
            case .tab: return .commit(then: modifiers.contains(.shift) ? .backtab : .tab)
            case .escape: return .commit(then: nil)
            default: return .none
            }
        }
        let command = modifiers.contains(.command)
        switch key {
        case .arrow(let move) where !command: return .move(move, extending: modifiers.contains(.shift))
        case .tab: return .move(modifiers.contains(.shift) ? .backtab : .tab, extending: false)
        case .enter where modifiers == [.shift, .command]: return .openInNewTab
        case .enter where modifiers.isEmpty: return .beginEditing(replacingWith: nil)
        case .escape: return .selectRow
        case .delete, .forwardDelete: return command ? .none : .erase
        case .character:
            if command {
                guard modifiers.subtracting(.shift) == .command else { return .none }
                switch characters?.lowercased() {
                case "c", "с": return .copy
                case "x", "ч": return .cut
                case "v", "м": return .paste
                case "a", "ф": return .selectAll
                case "d", "в": return .duplicateRows
                default: return .none
                }
            }
            guard !modifiers.contains(.control), let characters, let first = characters.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(first) else { return .none }
            return .beginEditing(replacingWith: characters)
        default: return .none
        }
    }
}
