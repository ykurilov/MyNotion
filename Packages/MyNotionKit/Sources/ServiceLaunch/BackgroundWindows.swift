import AppKit

/// Окна служебного запуска (`LaunchPresence.background`). SwiftUI не выводит окно приложения,
/// которому нельзя стать активным, — его выводит этот тип: под все окна, без активации и без смены фокуса.
@MainActor
public final class BackgroundWindows {
    public static let shared = BackgroundWindows()
    /// Только при запуске: позже скрытые окна того же уровня — закрытые меню и панели, их показывать нельзя.
    private var hasOrderedIn = false

    init() {}

    public func orderInMainWindow() {
        for window in windowsToOrderIn(from: NSApp.windows) { window.orderBack(nil) }
    }

    func windowsToOrderIn(from windows: [NSWindow]) -> [NSWindow] {
        guard !hasOrderedIn else { return [] }
        hasOrderedIn = true
        return windows.filter { $0.contentView != nil && !$0.isVisible && $0.level < .normal }
    }
}
