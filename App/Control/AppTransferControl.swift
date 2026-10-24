import ControlCommands
import Foundation
import NotionImport
import PageTree
import Sync

/// Импорт в окне и синхронизация для команд: ход импорта командой — та же карточка внизу окна, что у импорта из меню
/// (с «Остановить»); синхронизация — та же, что у значка боковой панели и «Синхронизировать сейчас».
@MainActor
final class AppTransferControl: TransferControl {
    /// Сколько `sync now` ждёт конца круга: дольше — ответ с текущим состоянием («sending»).
    static let syncNowWait: Duration = .seconds(15)

    private let importController: NotionImportController
    private let sync: SyncController

    init(importController: NotionImportController, sync: SyncController) {
        self.importController = importController
        self.sync = sync
    }

    var isImporting: Bool {
        switch importController.state {
        case .preparing, .running: true
        case .idle, .confirmRepeat, .finished, .failed: false
        }
    }

    func commandImportDidStart(stop: @escaping @MainActor () -> Void) {
        importController.beginCommandImport(stop: stop)
    }

    func commandImport(progress: NotionImportProgress) {
        importController.reportCommandImport(progress)
    }

    func commandImportDidFinish(_ outcome: Result<NotionImportReport, any Error>) {
        importController.endCommandImport()
    }

    var syncState: SyncState {
        // Синхронизация включена, но цикл не запущен — служебный запуск (галерея, замеры): для команд её нет.
        guard sync.isEnabled, sync.engine != nil, let badge = sync.badge else { return SyncState(status: .off) }
        let status: SyncState.Status = switch badge.kind {
        case .ready: .ready
        case .sending: .sending
        case .error: .error
        }
        return SyncState(status: status, detail: badge.detail, lastSyncedAt: badge.lastSyncedAt, deviceName: sync.deviceName)
    }

    func syncNow() async throws -> SyncState {
        guard let engine = sync.engine else { return syncState }
        let started = Date()
        sync.syncNow()
        // Круг прошёл — очередь отправлена и время синхронизации сдвинулось; помеха — сразу её текст.
        let deadline = ContinuousClock.now + Self.syncNowWait
        while ContinuousClock.now < deadline, !engine.status.isError {
            if engine.status == .ready, let last = engine.lastSyncedAt, last >= started { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        return syncState
    }
}
