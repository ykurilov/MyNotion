import AppKit

/// Окна служебного запуска (`LaunchPresence.background`). SwiftUI не выводит окно приложения,
/// которому нельзя стать активным, — его выводит этот тип: под все окна, без активации и без смены фокуса.
@MainActor
enum BackgroundWindows {
    static func orderInBehindEverything() {
        for window in NSApp.windows where window.contentView != nil && !window.isVisible && window.level < .normal {
            window.orderBack(nil)
        }
    }
}
