import Foundation

/// Обложка и вид страницы (research R1, R2; contracts/page-operations.md, «Обложка»): каждая правка — одно поле
/// со своей меткой часов и один шаг ⌘Z. Окно узнаёт о смене через `onAppearanceChange` и подставляет записанное
/// в открытый документ, не перечитывая страницу.
extension PageTreeOperations {
    /// Поставить, сменить или убрать (`nil`) обложку; сдвиг «Переместить» — та же правка с `actionName` «Положение обложки».
    public func setCover(_ pageId: UUID, to cover: PageCover?, actionName: String = "Обложка") throws {
        try setAppearance(pageId, actionName: actionName, \.cover, { _ in cover }) { operations, old in
            try operations.setCover(pageId, to: old, actionName: actionName)
        }
    }

    /// «Сохранить положение» режима «Переместить»: сдвиг обложки, урезанный к 0…1. Без обложки — ничего.
    public func setCoverOffset(_ pageId: UUID, _ offset: Double) throws {
        let actionName = "Положение обложки"
        try setAppearance(pageId, actionName: actionName, \.cover, { cover in
            cover.map { var moved = $0; moved.offset = offset; return moved }
        }) { operations, old in
            try operations.setCover(pageId, to: old, actionName: actionName)
        }
    }

    /// «Вид страницы» → «Широкая страница».
    public func setFullWidth(_ pageId: UUID, _ isOn: Bool) throws {
        try setAppearance(pageId, actionName: "Вид страницы", \.isFullWidth, { _ in isOn }) { operations, old in
            try operations.setFullWidth(pageId, old)
        }
    }

    /// «Вид страницы» → «Мелкий шрифт».
    public func setSmallText(_ pageId: UUID, _ isOn: Bool) throws {
        try setAppearance(pageId, actionName: "Вид страницы", \.isSmallText, { _ in isOn }) { operations, old in
            try operations.setSmallText(pageId, old)
        }
    }

    /// Записать поле страницы — новое значение из прежнего; то же значение — не правка и не шаг отмены.
    private func setAppearance<Value: Equatable>(
        _ pageId: UUID, actionName: String, _ field: WritableKeyPath<Page, Value>, _ value: (Value) -> Value,
        inverse: @escaping @MainActor (PageTreeOperations, Value) throws -> Void
    ) throws {
        let (old, changed) = try perform(notify: false) { transaction in
            guard var page = try transaction.page(pageId) else { throw NotesStoreError.pageNotFound(pageId) }
            let old = page[keyPath: field]
            page[keyPath: field] = value(old)
            guard page[keyPath: field] != old else { return (old, false) }
            try transaction.updatePage(page)
            return (old, true)
        }
        guard changed else { return }
        onAppearanceChange?(pageId)
        registerUndo(actionName) { try inverse($0, old) }
    }
}
