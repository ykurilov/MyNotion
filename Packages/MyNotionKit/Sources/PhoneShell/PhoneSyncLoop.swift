import Foundation
import NotesCore
import Sync

/// Цикл синхронизации, каким его видит оболочка iPhone: запустить, остановить, разбудить и спросить, всё ли ушло.
/// В приложении — `SyncEngine`; в тестах — подмена без сервера.
@MainActor
public protocol PhoneSyncLoop: AnyObject {
    var status: SyncStatus { get }
    var lastSyncedAt: Date? { get }
    func start()
    func stop()
    func syncNow()
    /// В очереди исходящих есть правки, которые ещё не ушли на сервер.
    func hasUnsentChanges() -> Bool
}

extension SyncEngine: PhoneSyncLoop {
    public func hasUnsentChanges() -> Bool {
        (try? Outbox(store: store).isEmpty()) == false
    }
}

/// Фоновое время, которое система даёт приложению после ухода с экрана (на iPhone — `beginBackgroundTask`).
@MainActor
public protocol BackgroundTimeGrant: AnyObject {
    /// `nil` — система времени не дала. `expiration` — время кончается: остановиться и вернуть его.
    func begin(expiration: @escaping @MainActor () -> Void) -> BackgroundTimeToken?
    func end(_ token: BackgroundTimeToken)
}

public struct BackgroundTimeToken: Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

/// Без фонового времени: цикл останавливается сразу при уходе в фон.
@MainActor
public final class NoBackgroundTime: BackgroundTimeGrant {
    public init() {}
    public func begin(expiration: @escaping @MainActor () -> Void) -> BackgroundTimeToken? { nil }
    public func end(_ token: BackgroundTimeToken) {}
}
