import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Меню — отдельные окна поверх страницы. Окно страницы в проверках не выводится на экран, и меню тоже не должно:
/// иначе прогон `swift test` показывает их поверх чужих программ. Место меню при этом считается.
@MainActor
@Suite("Меню не выходят на экран без окна страницы")
struct PopupOffscreenTests {
    private func onScreenMenus() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && ["slash-menu", "block-menu"].contains($0.accessibilityIdentifier()) }
    }

    @Test("Меню «/» и меню блока при невидимом окне: открыты, место посчитано, на экране нет")
    func menusStayOffscreen() throws {
        let editor = try EditorFixture([.paragraph("дело"), .paragraph("ещё")])
        #expect(!editor.textView.window!.isVisible)
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type(" /")
        #expect(editor.textView.popups.isOpen)
        #expect(editor.textView.popups.menuFrame != nil, "Место меню посчитано")
        #expect(onScreenMenus().isEmpty, "Меню «/» вышло на экран")
        editor.type("за")
        #expect(onScreenMenus().isEmpty, "Суженное меню «/» вышло на экран")
        editor.textView.popups.close()

        editor.textView.openBlockMenu(forBlock: editor.document.blocks[1].id, below: .zero)
        #expect(editor.textView.popups.isOpen)
        #expect(onScreenMenus().isEmpty, "Меню блока вышло на экран")
        editor.textView.popups.close()
    }

    @Test("Приложение ушло в фон — открытое меню закрывается, как в Notion")
    func menuClosesOnDeactivation() throws {
        let editor = try EditorFixture([.paragraph("дело")])
        editor.placeCaret(inBlock: 0, at: nil)
        editor.type(" /")
        #expect(editor.textView.popups.isOpen)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(!editor.textView.popups.isOpen)
    }
}
