import NotesCore

/// Виды блоков, которые редактор рисует сам — их модули он знает напрямую (код, формула, оглавление).
/// Остальные (картинки, файлы, видео) регистрирует приложение (`BlockViewFactories`).
@MainActor
enum BuiltInBlockViews {
    private static var isRegistered = false

    static func registerOnce() {
        guard !isRegistered else { return }
        isRegistered = true
        BlockViewFactories.shared.register(CodeBlockViewFactory(), for: .code)
    }
}
