import PhoneShell
import Sync
import UIKit

/// Тихие пуши: система выдаёт токен — он уходит серверу синхронизации; пуш будит приложение —
/// синхронизация забирает правки одним кругом и говорит системе, что вышло.
/// Пуш не будит приложение, которое пользователь смахнул из переключателя: это решает iOS.
@MainActor
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    /// Задаётся при запуске приложения, до первого вызова делегата.
    static var library: PhoneLibrary?
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
        Self.library?.sync.didReceivePushToken(deviceToken, environment: Self.pushEnvironment)
        Self.log.write("push-token: \(Self.pushEnvironment.rawValue)")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.log.write("push-token-error: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard let sync = Self.library?.sync else { return .noData }
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
