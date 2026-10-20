import Foundation
import NotesCore

/// Шаблоны (US7): отметка страницы, новая страница по шаблону, заполнение пустой страницы. Операции — `PageTreeOperations+Templates`
/// с отменой окна.
extension MainWindowModel {
    func toggleTemplate(_ pageId: UUID) {
        performTreeOperation {
            if isTemplate(pageId) { try treeOperations.stopBeingTemplate(pageId) } else { try treeOperations.makeTemplate(pageId) }
        }
    }

    func isTemplate(_ pageId: UUID) -> Bool { tree.page(pageId)?.isTemplate ?? false }

    /// «Новая страница по шаблону»: копия с подстраницами в корне «Страниц» открывается, курсор в названии.
    func createPage(fromTemplate templateId: UUID) {
        if let page = performTreeOperation({ try treeOperations.createPage(fromTemplate: templateId) }) {
            navigate(to: page.id, focus: .title)
        }
    }
}
