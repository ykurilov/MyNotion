import NotesCore

/// Виды кода, формулы и оглавления: их модули редактор знает напрямую. Колонки и таблица — `BuiltInBlockViews`,
/// картинки, файлы, видео регистрирует приложение (`BlockViewFactories`).
@MainActor
enum CodeMathBlockViews {
    private static var isRegistered = false

    static func registerOnce() {
        guard !isRegistered else { return }
        isRegistered = true
        BlockViewFactories.shared.register(CodeBlockViewFactory(), for: .code)
        BlockViewFactories.shared.register(EquationBlockViewFactory(), for: .equation)
        BlockViewFactories.shared.register(TableOfContentsViewFactory(), for: .tableOfContents)
    }
}
