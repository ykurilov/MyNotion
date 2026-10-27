import PhoneShell
import Sync
import UIKit

/// Тихие пуши: система выдаёт токен — он уходит серверу синхронизации; пуш будит приложение —
/// синхронизация забирает правки одним кругом и говорит системе, что вышло.
/// Пуш не будит приложение, которое пользователь смахнул из переключателя: это решает iOS.
@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    /// Задаётся при запуске приложения, до первого вызова делегата.
    static var opener: PhoneLibraryOpener?
    /// Токен от системы: если база ещё не открылась, он передаётся синхронизации, когда откроется.
    private static var pushToken: Data?
    /// Журнал живой проверки (`--sync-log`).
    static var log = LiveCheckLog(url: nil)

    /// Среда Apple для токена: отладочная сборка подписана для разработки, TestFlight и App Store — для выкладки.
    private static var pushEnvironment: SyncPushEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.pushToken = deviceToken
        Self.deliverPushToken()
        Self.log.write("push-token: \(Self.pushEnvironment.rawValue)")
    }

    /// Токен — синхронизации, если база открыта; тот же токен повторно на сервер не уходит.
    static func deliverPushToken() {
        guard let pushToken, let library = opener?.library else { return }
        library.sync.didReceivePushToken(pushToken, environment: pushEnvironment)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.log.write("push-token-error: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // База не открылась (iPhone ещё не разблокировали после перезагрузки) — честное «не вышло»; откроется в следующий раз.
        guard let sync = Self.opener?.library?.sync else { return .failed }
        Self.deliverPushToken()
        // Система запустила приложение ради пуша и на экран оно не выходило: цикл, запущенный при старте, — остановить.
        // При запуске со сценами приложение всегда стартует «в фоне», поэтому проверка здесь, а не при запуске.
        if application.applicationState == .background { sync.didLaunchInBackground() }
        Self.log.write("push-received: \(application.applicationState == .active ? "на экране" : "в фоне")")
        let outcome = await sync.handleBackgroundPush()
        Self.log.write("push-handled: \(outcome) remote-changes=\(sync.remoteChangeCount)")
        return switch outcome {
        case .newData: .newData
        case .noData: .noData
        case .failed: .failed
        }
    }
}
