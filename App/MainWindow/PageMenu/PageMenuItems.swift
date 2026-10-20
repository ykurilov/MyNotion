import Foundation
import PageEditor

/// Пункты меню «•••» страницы (contracts/pages-ui.md): файл на пункт в `App/MainWindow/PageMenu/`.
/// Пункты будущих историй — заготовки `nil`, история заменяет свой файл.
@MainActor
enum PageMenuItems {
    static func all(for model: MainWindowModel, pageId: UUID) -> [PageMenuItem] {
        [findAction, footer, trash(model, pageId), duplicate(model, pageId), moveTo(model, pageId), versionHistory(model, pageId),
         appearance(model, pageId), template(model, pageId)].compactMap { $0 }
    }
}
