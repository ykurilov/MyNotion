import Foundation
import PageEditor

extension PageMenuItems {
    /// «Вид страницы ›» — «Мелкий шрифт» и «Широкая страница» (contracts/pages-ui.md, US1); каждое переключение —
    /// правка страницы с ⌘Z.
    static func appearance(_ model: MainWindowModel, _ pageId: UUID) -> PageMenuItem? {
        PageMenuItem(slot: .appearance, title: { _ in "Вид страницы" }, kind: .toggles([
            PageMenuToggle(title: "Мелкий шрифт", identifier: "page-appearance-small-text", isOn: { $0.page.isSmallText },
                           toggle: { model.setSmallText(pageId, !$0.page.isSmallText) }),
            PageMenuToggle(title: "Широкая страница", identifier: "page-appearance-full-width", isOn: { $0.page.isFullWidth },
                           toggle: { model.setFullWidth(pageId, !$0.page.isFullWidth) }),
        ]))
    }
}
