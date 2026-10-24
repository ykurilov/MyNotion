import Foundation
import PageEditor

extension PageMenuItems {
    /// «Выгрузить базу…» у страницы-базы (US7, FR-334): CSV, Markdown строк и схема — в выбранную папку.
    static func exportDatabase(_ model: MainWindowModel, _ pageId: UUID) -> PageMenuItem? {
        guard model.tree.isDatabase(pageId) else { return nil }
        return PageMenuItem(slot: .exportDatabase, title: { _ in "Выгрузить базу…" },
                            kind: .action({ context in
                                AppDelegate.exportController?.chooseFolderAndExportDatabase(pageId, title: context.page.displayTitle)
                            }))
    }
}
