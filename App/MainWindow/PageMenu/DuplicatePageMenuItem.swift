import Foundation
import PageEditor

extension PageMenuItems {
    /// «Дублировать» ⌘D (US4): копия с подстраницами под оригиналом, открывается она.
    static func duplicate(_ model: MainWindowModel, _ pageId: UUID) -> PageMenuItem? {
        PageMenuItem(slot: .duplicate, title: { _ in "Дублировать" }, kind: .action({ _ in model.duplicatePage(pageId) }, shortcut: "⌘D"))
    }
}
