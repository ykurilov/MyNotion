import Foundation
import PageEditor

extension PageMenuItems {
    /// «Переместить в» ⇧⌘P (US4): окно выбора страницы у «•••»; страница — внутрь выбранной или на верхний уровень.
    static func moveTo(_ model: MainWindowModel, _ pageId: UUID) -> PageMenuItem? {
        PageMenuItem(slot: .moveTo, title: { _ in "Переместить в" }, kind: .action({ _ in model.showMovePagePicker(pageId) }, shortcut: "⌘⇧P"))
    }
}
