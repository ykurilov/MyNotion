import Foundation

extension PageTreeOperations {
    /// Страница в корне последней среди соседей, как «Новая страница» в окне. Отмена уводит её в корзину: набранное
    /// в ней за это время не пропадает.
    @discardableResult
    public func createRootPage(title: String = "") throws -> Page {
        let page = try perform { transaction in try transaction.createPage(title: title) }
        registerUndo("Новая страница") { try $0.moveToTrash(page.id) }
        return page
    }
}
