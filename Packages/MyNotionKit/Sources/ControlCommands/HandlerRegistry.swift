import ControlProtocol

/// Обработчики по имени команды. У каждой группы свой файл `Handlers/<Группа>Handlers.swift` со словарём `all`;
/// этап 005 дописывает только свой словарь. Команда без обработчика отвечает `not_implemented` с номером этапа.
public struct HandlerRegistry: Sendable {
    let handlers: [String: CommandHandler]

    public init(_ handlers: [String: CommandHandler]) {
        self.handlers = handlers
    }

    public static let standard = HandlerRegistry([
        ServiceHandlers.all, PageHandlers.all, BlockHandlers.all, DatabaseHandlers.all, LibraryHandlers.all, WindowHandlers.all,
        TransferHandlers.all, ShareHandlers.all,
    ].reduce(into: [:]) { result, group in
        result.merge(group) { first, _ in first }
    })

    public func handler(for name: String) -> CommandHandler? {
        handlers[name]
    }
}
