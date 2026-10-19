import AppKit

extension PageTextView {
    /// Редакторы, которые сейчас живут: страницы, колонок, ячеек. По ним правка из документа узнаёт, общая ли отмена
    /// у её автора и у этого редактора.
    static let liveEditors = NSHashTable<PageTextView>.weakObjects()

    /// Правку сделал редактор с той же отменой — или она сделана прямо через документ от имени этой отмены
    /// (`origin` — сама отмена окна: колонки, таблица, перенос между потоками).
    func sharesUndo(withEditOrigin origin: ObjectIdentifier?) -> Bool {
        guard let origin, let undoManager else { return false }
        if origin == ObjectIdentifier(undoManager) { return true }
        return Self.liveEditors.allObjects.contains { editor in
            editor.textStorage.map(ObjectIdentifier.init) == origin && editor.undoManager === undoManager
        }
    }
}
