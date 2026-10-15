import AppKit
import Testing
@testable import ServiceLaunch

/// Окно служебного запуска выводится под все окна один раз — при запуске. Закрытые потом меню «/»,
/// меню блока и окно корзины тоже скрыты и на том же уровне, но показывать их снова нельзя:
/// иначе на снимках висят меню прошлых состояний, а щелчок по «Корзине» закрывает её вместо открытия.
@MainActor
@Suite("Окна служебного запуска")
struct BackgroundWindowsTests {
    static func window(level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.level = level
        window.isReleasedWhenClosed = false
        return window
    }

    static let desktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

    @Test("При запуске выводится скрытое главное окно, служебные окна обычного уровня — нет")
    func firstCallOrdersInMainWindow() {
        let main = Self.window(level: Self.desktop)
        let textInput = Self.window(level: .normal)
        let ordering = BackgroundWindows()
        #expect(ordering.windowsToOrderIn(from: [main, textInput]) == [main])
    }

    @Test("Повторная готовность редактора (новая страница) закрытые меню и панели не показывает")
    func laterCallsShowNothing() {
        let main = Self.window(level: Self.desktop)
        let ordering = BackgroundWindows()
        _ = ordering.windowsToOrderIn(from: [main])
        let closedSlashMenu = Self.window(level: Self.desktop)
        let closedTrashPanel = Self.window(level: Self.desktop)
        #expect(ordering.windowsToOrderIn(from: [main, closedSlashMenu, closedTrashPanel]).isEmpty)
    }
}
