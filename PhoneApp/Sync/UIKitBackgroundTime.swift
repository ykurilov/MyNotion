import PhoneShell
import UIKit

/// Фоновое время iPhone: `beginBackgroundTask` — обычно до 30 секунд после ухода приложения с экрана.
@MainActor
final class UIKitBackgroundTime: BackgroundTimeGrant {
    func begin(expiration: @escaping @MainActor () -> Void) -> BackgroundTimeToken? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "MyNotion: отправка правок") {
            MainActor.assumeIsolated { expiration() }
        }
        return identifier == .invalid ? nil : BackgroundTimeToken(rawValue: identifier.rawValue)
    }

    func end(_ token: BackgroundTimeToken) {
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token.rawValue))
    }
}
