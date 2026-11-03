import Databases
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
        if let row = openDocuments.document(for: pageId), isDatabaseRow(row) {
            return row.page.isTemplate ? [] : rowTemplateChoices(of: row.page.parentId)
        }
        return library.templatePageIds.compactMap { id in
            guard let template = tree.page(id), !tree.isPage(pageId, insideBranchOf: id) else { return nil }
            return TemplateChoice(id: id, title: template.title, icon: template.icon)
        }
    }

    /// Строка шаблона на пустой странице: страница заполняется копией, открывается заново, курсор в названии.
    func fillOpenPage(_ pageId: UUID, fromTemplate templateId: UUID) {
        reopenFocus = .title
        defer { reopenFocus = nil }
        if rowDatabaseId(pageId) != nil {
            do { try databaseOperations.applyRowTemplate(templateId, toRow: pageId) } catch {
                showError("Не удалось применить шаблон: \(SaveStatus.reason(for: error))")
            }
            return
        }
        performTreeOperation { try treeOperations.fill(pageId, fromTemplate: templateId) }
    }

    /// Шаблоны строк базы (US6) на пустой странице её строки: у самого шаблона строки шаблонов нет.
    private func rowTemplateChoices(of databaseId: UUID?) -> [TemplateChoice] {
        guard let databaseId else { return [] }
        return ((try? RowTemplates.list(of: databaseId, in: store))?.templates ?? [])
            .map { TemplateChoice(id: $0.id, title: $0.title, icon: $0.icon) }
    }

    /// База строки — у открытой строки, которая сама не шаблон строки.
    private func rowDatabaseId(_ pageId: UUID) -> UUID? {
        guard let document = openDocuments.document(for: pageId), isDatabaseRow(document), !document.page.isTemplate else { return nil }
        return document.page.parentId
    }
}
