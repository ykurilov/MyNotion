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
            Button("Подчёркнутый") { send(#selector(PageTextView.toggleUnderlineStyle(_:))) }
                .keyboardShortcut("u")
            Button("Зачёркнутый") { send(#selector(PageTextView.toggleStrikethroughStyle(_:))) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Код") { send(#selector(PageTextView.toggleCodeStyle(_:))) }
                .keyboardShortcut("e")
            Button("Повторить последний цвет") { send(#selector(PageTextView.repeatLastColorStyle(_:))) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Текст") { send(#selector(PageTextView.turnIntoText(_:))) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("Заголовок 1") { send(#selector(PageTextView.turnIntoHeading1(_:))) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Заголовок 2") { send(#selector(PageTextView.turnIntoHeading2(_:))) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Заголовок 3") { send(#selector(PageTextView.turnIntoHeading3(_:))) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
            Button("Ссылка…") { send(#selector(PageTextView.editLink(_:))) }
        }
    }

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
