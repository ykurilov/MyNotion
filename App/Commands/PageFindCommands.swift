import AppKit
import SwiftUI

/// «Правка → Найти на странице» ⌘F, ⌘G, ⇧⌘G: одна полоса поиска на всю страницу с колонками и ячейками
/// (research R4). Действие уходит в текст под курсором — страницы, колонки или ячейки, — а он отдаёт его поиску страницы.
struct PageFindCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Найти на странице…") { send(.showFindInterface) }
                .keyboardShortcut("f")
            Button("Найти далее") { send(.nextMatch) }
                .keyboardShortcut("g")
            Button("Найти ранее") { send(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }

    /// Системный поиск узнаёт действие по метке отправителя.
    private func send(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    }
}
