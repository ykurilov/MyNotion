import AppKit
import Testing
@testable import PageTree

/// Окно корзины и вопрос удаления — отдельные окна. Без окна приложения на экране они не выводятся:
/// прогон `swift test` не должен показывать их поверх чужих программ.
@MainActor
@Suite("Окно корзины и вопрос не выходят на экран без окна приложения")
struct TrashOffscreenTests {
    private static func hiddenParent() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func onScreen(_ identifier: String) -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.accessibilityIdentifier() == identifier }
    }

    @Test("Корзина при невидимом окне не выходит на экран")
    func trashPanelStaysOffscreen() {
        let parent = Self.hiddenParent()
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        parent.contentView?.addSubview(anchor)
        let controller = TrashPanelController()
        controller.anchorView = anchor
        controller.toggle(entries: [], actions: TrashActions(restore: { _ in }, deleteForever: { _ in }, emptyTrash: {}))
        #expect(!onScreen("trash-panel"))
        controller.close()
    }

    @Test("Вопрос удаления при невидимом окне не выходит на экран")
    func dialogStaysOffscreen() {
        let parent = Self.hiddenParent()
        ConfirmationDialogWindow.present(over: parent, title: "Удалить?", message: "", action: "Удалить навсегда") { _ in }
        #expect(!onScreen("confirmation-dialog"))
        for window in NSApp.windows where window.accessibilityIdentifier() == "confirmation-dialog" { window.close() }
    }
}
