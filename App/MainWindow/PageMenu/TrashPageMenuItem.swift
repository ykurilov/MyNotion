import Foundation
import PageEditor

extension PageMenuItems {
    /// «Удалить в корзину» (⌘⌫, как в 001).
    static func trash(_ model: MainWindowModel, _ pageId: UUID) -> PageMenuItem? {
        PageMenuItem(slot: .trash, title: { _ in "Удалить в корзину" }, kind: .action({ _ in model.moveToTrash(pageId) }, shortcut: "⌘⌫"))
    }
}
