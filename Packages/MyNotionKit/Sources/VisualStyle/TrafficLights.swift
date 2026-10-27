#if canImport(AppKit)
import AppKit

/// Кнопки окна Mac (светофор) на месте Notion (contracts/visual-style.md, «Боковая панель»): середина красной —
/// `Metrics.Window.trafficLightsCenter` от левого верхнего угла окна, шаг между кнопками системный.
/// Система ставит кнопки заново при каждом изменении окна — ставим их следом. В полноэкранном режиме кнопки живут
/// в системной выезжающей строке: их не трогаем.
@MainActor
public enum TrafficLights {
    private static var placedWindows: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    /// Поставить кнопки окна на место и держать их там, пока окно открыто. Повторный вызов ничего не меняет.
    public static func keepInPlace(in window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard placedWindows[key] == nil, let close = window.standardWindowButton(.closeButton) else { return }
        let center = NotificationCenter.default
        close.postsFrameChangedNotifications = true
        let placeAgain: @Sendable (Notification) -> Void = { [weak window] _ in
            MainActor.assumeIsolated { if let window { TrafficLights.place(in: window) } }
        }
        var observers = [
            center.addObserver(forName: NSView.frameDidChangeNotification, object: close, queue: .main, using: placeAgain),
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: placeAgain),
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main, using: placeAgain),
        ]
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                placedWindows.removeValue(forKey: key)?.forEach(center.removeObserver)
            }
        })
        placedWindows[key] = observers
        place(in: window)
    }

    private static func place(in window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
        guard let close = buttons.first, let superview = close.superview else { return }
        let height = window.frame.height
        let closeInWindow = superview.convert(NSPoint(x: close.frame.midX, y: close.frame.midY), to: nil)
        let target = Metrics.Window.trafficLightsCenter
        let dx = target.x - closeInWindow.x
        // Окно считает y снизу, Metrics — сверху.
        let down = target.y - (height - closeInWindow.y)
        guard abs(dx) > 0.01 || abs(down) > 0.01 else { return }
        let dy = superview.isFlipped ? down : -down
        for button in buttons {
            button.setFrameOrigin(NSPoint(x: button.frame.origin.x + dx, y: button.frame.origin.y + dy))
        }
    }
}
#endif
