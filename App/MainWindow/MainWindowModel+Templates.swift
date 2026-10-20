import Foundation
import NotesCore
import PageEditor

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

    /// Шаблоны для строк на пустой странице: кроме тех, чья ветка содержит саму страницу (на себя шаблон не кладут).
    func templateChoices(forPage pageId: UUID) -> [TemplateChoice] {
        library.templatePageIds.compactMap { id in
            guard let template = tree.page(id), !tree.isPage(pageId, insideBranchOf: id) else { return nil }
            return TemplateChoice(id: id, title: template.title, icon: template.icon)
        }
    }

    /// Строка шаблона на пустой странице: страница заполняется копией, открывается заново, курсор в названии.
    func fillOpenPage(_ pageId: UUID, fromTemplate templateId: UUID) {
        reopenFocus = .title
        defer { reopenFocus = nil }
        performTreeOperation { try treeOperations.fill(pageId, fromTemplate: templateId) }
    }
}
