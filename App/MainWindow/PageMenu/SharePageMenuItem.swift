import Foundation
import PageEditor

extension PageMenuItems {
    /// «Поделиться» (006): ссылка на страницу только для чтения.
    static func share(_ model: MainWindowModel, _ pageId: UUID) -> PageMenuItem? {
        .action(.share, "Поделиться") { _ in model.showShareDialog(pageId) }
    }
}
