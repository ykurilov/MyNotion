import AppKit

/// Окна поверх окна приложения: меню «/» и блока, окно корзины, вопрос удаления. Они выводятся только над окном,
/// которое видно на экране: в модульных проверках окно страницы невидимо, и меню не должны всплывать поверх
/// чужих программ. Место такого окна при этом считается как обычно.
@MainActor
public enum PopupWindows {
    /// Вывести `child` над `parent`; `false` — родитель не на экране, ничего не выведено.
    @discardableResult
    public static func show(_ child: NSWindow, over parent: NSWindow, makingKey: Bool = false) -> Bool {
        guard parent.isVisible else { return false }
        if child.parent !== parent {
            child.parent?.removeChildWindow(child)
            parent.addChildWindow(child, ordered: .above)
        }
        if makingKey { child.makeKeyAndOrderFront(nil) } else { child.orderFront(nil) }
        return true
    }

    /// Приложение ушло в фон: `action` убирает окна, как в Notion — меню не висят над чужими окнами.
    /// Подписку держит вызывающий; снять — `NotificationCenter.default.removeObserver`.
    public static func onAppDeactivation(_ action: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
    }
}
