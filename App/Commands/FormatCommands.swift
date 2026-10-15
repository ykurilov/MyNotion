import AppKit
import PageEditor
import SwiftUI

/// Меню «Формат»: оформление выделенного текста в открытой странице (contracts/editor-interactions.md).
/// Команды уходят первому отвечающему — тексту страницы; вне текста они ничего не делают.
struct FormatCommands: Commands {
    var body: some Commands {
        CommandMenu("Формат") {
            Button("Жирный") { send(#selector(PageTextView.toggleBoldStyle(_:))) }
                .keyboardShortcut("b")
            Button("Курсив") { send(#selector(PageTextView.toggleItalicStyle(_:))) }
                .keyboardShortcut("i")
            Button("Зачёркнутый") { send(#selector(PageTextView.toggleStrikethroughStyle(_:))) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Код") { send(#selector(PageTextView.toggleCodeStyle(_:))) }
                .keyboardShortcut("e")
            Divider()
            Button("Ссылка…") { send(#selector(PageTextView.editLink(_:))) }
        }
    }

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
