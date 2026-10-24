import AppKit
import DatabaseRowPage
import Databases
import Foundation
import Navigation
import NotesCore
import PageEditor

/// Строка базы, открытая просмотром поверх окна (contracts/database-ui.md, «Страница строки»): сбоку или по центру.
/// Документ держится открытым, пока виден просмотр (`OpenDocuments.open` / `release`).
struct RowPeek {
    let document: PageDocument
    let mode: RowOpenMode
    /// Куда поставить курсор: у новой строки без названия — в название (как «Создать» в Notion).
    let focus: PageTextView.InitialFocus
}

/// Открыть строку базы (US1, сценарий 6): сбоку, по центру или на всю страницу; новой вкладкой — всегда на всю страницу.
extension MainWindowModel {
    func openRow(_ rowId: UUID, mode: RowOpenMode, inNewTab: Bool = false) {
        guard !inNewTab, mode != .fullPage else {
            closeRowPeek()
            return open(PageOpenRequest(pageId: rowId, inNewTab: inNewTab))
        }
        do {
            // Новый документ — до того, как отпустить прежний: та же строка второй раз не перечитывается.
            let document = try openDocuments.open(rowId)
            closeRowPeek()
            rowPeek = RowPeek(document: document, mode: mode, focus: document.page.title.isEmpty ? .title : .unchanged)
        } catch {
            showError("Не удалось открыть строку: \(SaveStatus.reason(for: error))")
        }
    }

    /// «»», Esc, щелчок мимо карточки, переход на другую страницу.
    func closeRowPeek() {
        guard let rowPeek else { return }
        self.rowPeek = nil
        openDocuments.release(rowPeek.document.pageId)
    }

    /// «⤢»: строка из просмотра — на всю страницу в активной вкладке.
    func expandRowPeek() {
        guard let rowId = rowPeek?.document.pageId else { return }
        closeRowPeek()
        open(PageOpenRequest(pageId: rowId))
    }

    /// Страница — строка базы (её родитель — страница-база). Строк в дереве панели нет (research R1).
    func isDatabaseRow(_ document: PageDocument) -> Bool {
        document.page.parentId.map(tree.isDatabase) ?? false
    }

    /// Открытая на всю страницу строка жива: в дереве её нет, поэтому — по документу и корзине.
    func isLiveRow(_ pageId: UUID) -> Bool {
        guard let document = openDocuments.document(for: pageId), isDatabaseRow(document) else { return false }
        return library.trashedPagesById[pageId] == nil && !library.isDeletedForever(pageId)
    }

    /// Путь строки в верхней полосе: путь базы и сама база («Родитель / … / Задачи / Строка»).
    func rowBreadcrumbAncestors(of pageId: UUID) -> [BreadcrumbAncestor]? {
        guard tree.page(pageId) == nil, let document = openDocuments.document(for: pageId), isDatabaseRow(document),
              let databaseId = document.page.parentId, let database = tree.page(databaseId) else { return nil }
        return (tree.ancestors(of: databaseId) + [database]).map(BreadcrumbAncestor.init(page:))
    }

    /// Правка баз этого окна: открытые строки (на всю страницу и в просмотре) принимают записанное на месте —
    /// название из таблицы, корзину; редактор не пересоздаётся, как при операциях с деревом.
    func databaseDidChange(_ touched: Set<UUID>) {
        let rows = touched.filter { pageId in openDocuments.document(for: pageId).map(isDatabaseRow) ?? false }
        if !rows.isEmpty { openDocuments.applyExternalChanges(toPages: rows) }
        library.treeDidChange(touched)
        // Строку из просмотра убрали в корзину или стёрли — просмотр закрывается.
        if let rowPeek, !isLiveRow(rowPeek.document.pageId) { closeRowPeek() }
    }

    /// Добавки шапки страницы строки: свойства под названием. У обычной страницы — ничего.
    func rowPageAddonFactory() -> PageHeaderAddonFactory {
        { [weak self] document in
            guard let self, isDatabaseRow(document) else { return NoHeaderAddon() }
            let addon = RowPropertiesAddon(rowId: document.pageId, operations: databaseOperations)
            addon.onError = { [weak self] error in self?.showError("Не удалось изменить значение: \(SaveStatus.reason(for: error))") }
            addon.onAddProperty = { [weak self] anchor in self?.addRowProperty(document.pageId, anchor: anchor) }
            return addon
        }
    }
}

/// Пустая добавка: страница не строка базы.
@MainActor
private final class NoHeaderAddon: PageHeaderAddon {
    func install(in textView: PageTextView) {}
    func pageDidChange(_ page: Page, in textView: PageTextView) {}
}
