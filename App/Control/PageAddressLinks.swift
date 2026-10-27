import AppKit
import ControlCommands
import Foundation

/// Щелчок по `mynotion://page/<id>` в другой программе (чат агента, терминал, браузер): macOS запускает приложение, если
/// оно закрыто, и присылает адрес событием «открыть адрес». Обработчик ставится до конца запуска: иначе адрес достался бы
/// SwiftUI, и тот открыл бы на него лишнее пустое окно.
@MainActor
final class PageAddressLinks: NSObject {
    private static let shared = PageAddressLinks()

    static func install() {
        NSAppleEventManager.shared().setEventHandler(shared, andSelector: #selector(handle(_:withReplyEvent:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handle(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        Task { await Self.open(url) }
    }

    /// Не вышло (страница в корзине, не найдена) — короткое окно с объяснением.
    private static func open(_ url: URL) async {
        guard let executor = ControlBootstrap.executor, let problem = await executor.openPageAddress(url) else { return }
        let alert = NSAlert()
        alert.messageText = "Страницу не открыть"
        alert.informativeText = problem
        NSApp.activate()
        alert.runModal()
    }
}
