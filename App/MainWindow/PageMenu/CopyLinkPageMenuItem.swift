import Foundation
import PageEditor

extension PageMenuItems {
    /// «Копировать ссылку» ⌘L: адрес `mynotion://page/<id>` в буфер обмена — дать агенту или открыть щелчком.
    static func copyLink(_ model: MainWindowModel, _ pageId: UUID) -> PageMenuItem? {
        PageMenuItem(slot: .copyLink, title: { _ in PageLinkCopy.title }, kind: .action({ _ in model.copyLink(pageId) }, shortcut: "⌘L"))
    }
}
