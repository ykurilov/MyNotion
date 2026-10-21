import Foundation
import PageEditor

extension PageMenuItems {
    /// «Выгрузить базу» у страницы-базы (US7, contracts/database-ui.md, «/» и меню страницы): Markdown и CSV со схемой.
    /// Место в меню — этапа 0; пункт делает US7 (пока `nil` — пункта нет).
    static func exportDatabase(_ model: MainWindowModel, _ pageId: UUID) -> PageMenuItem? {
        nil
    }
}
