import Foundation
import PageEditor

extension PageMenuItems {
    /// «История версий» (US6): окно истории на всё окно поверх панели и страницы.
    static func versionHistory(_ model: MainWindowModel, _ pageId: UUID) -> PageMenuItem? {
        .action(.versionHistory, "История версий") { _ in model.showVersionHistory(pageId) }
    }
}
