import AppKit
import SwiftUI

/// Вкладки и «назад/вперёд» в меню Mac, как у Notion 7.39 (contracts/pages-ui.md, «Клавиши»):
/// «Файл» — Новая вкладка ⌘T, Открыть закрытую вкладку ⇧⌘T, Закрыть вкладку ⌘W; «История» (между «Вид» и «Окно») —
/// Назад ⌘[, Вперёд ⌘]; «Окно» — Предыдущая вкладка ⌃⇧⇥, Следующая вкладка ⌃⇥. Действуют в окне, где работают.
struct NavigationCommands: Commands {
    let library: PagesLibrary?
    @FocusedValue(\.windowModel) private var focusedModel

    private var model: MainWindowModel? { focusedModel ?? library?.activeWindow }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Новая вкладка") { model?.showNewTabSearch() }
                .keyboardShortcut("t")
                .disabled(model == nil)
            Button("Открыть закрытую вкладку") { model?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model?.hasClosedTabs != true)
        }
        // «Закрыть» системы заменяет «Закрыть вкладку»: последняя вкладка закрывает окно.
        CommandGroup(replacing: .saveItem) {
            Button("Закрыть вкладку") {
                if let model { model.closeActiveTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
        }
        CommandMenu("История") {
            Button("Назад") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(model?.canGoBack != true)
            Button("Вперёд") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(model?.canGoForward != true)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Предыдущая вкладка") { model?.showPreviousTab() }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(model == nil)
            Button("Следующая вкладка") { model?.showNextTab() }
                .keyboardShortcut(.tab, modifiers: [.control])
                .disabled(model == nil)
        }
    }
}
