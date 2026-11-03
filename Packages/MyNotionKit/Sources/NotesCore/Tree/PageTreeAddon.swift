import Foundation

/// Добавка модуля к операциям дерева (004, конституция V): копия ветки и перенос страницы к другому родителю дописывают
/// записи модуля в той же транзакции, до подписчиков записи, — их видят поиск и синхронизация, отменяет тот же шаг ⌘Z.
/// Ядро о базах не знает: «Дублировать» базу и «Переместить в» строки делает модуль `Databases`.
public protocol PageTreeAddon: Sendable {
    /// Ветка скопирована `PageBranchCopier` («Дублировать», страница по шаблону, строка по шаблону).
    func branchCopied(_ copy: PageBranchCopier.Result, in transaction: NotesTransaction) throws
    /// Страница перенесена к другому родителю («Переместить в», перетаскивание в панели, их отмена).
    func pageMoved(_ pageId: UUID, from oldParentId: UUID?, to newParentId: UUID?, in transaction: NotesTransaction) throws
}
