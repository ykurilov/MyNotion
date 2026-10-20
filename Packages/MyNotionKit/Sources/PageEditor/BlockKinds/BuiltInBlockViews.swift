import NotesCore

/// Виды блоков, которые редактор знает напрямую: код, формула, оглавление, колонки, таблица.
/// Картинки, файлы, видео регистрирует приложение (`BlockViewFactories`).
@MainActor
enum BuiltInBlockViews {
    private static var isRegistered = false

    static func registerOnce() {
        guard !isRegistered else { return }
        isRegistered = true
        BlockViewFactories.shared.register(CodeBlockViewFactory(), for: .code)
        BlockViewFactories.shared.register(EquationBlockViewFactory(), for: .equation)
        BlockViewFactories.shared.register(TableOfContentsViewFactory(), for: .tableOfContents)
        BlockViewFactories.shared.register(ColumnsViewFactory(), for: .columnList)
        BlockViewFactories.shared.register(TableViewFactory(), for: .table)
    }
}
