import ControlCommands
import Foundation

/// Импорт, выгрузка и синхронизация для команд. Пока только «идёт ли импорт» для `app status`; остальное — этап 7.
@MainActor
final class AppTransferControl: TransferControl {
    private let importController: NotionImportController

    init(importController: NotionImportController) {
        self.importController = importController
    }

    var isImporting: Bool {
        switch importController.state {
        case .preparing, .running: true
        case .idle, .confirmRepeat, .finished, .failed: false
        }
    }
}
