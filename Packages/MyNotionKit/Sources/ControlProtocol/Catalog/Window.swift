import Foundation

/// Окна, вкладки, «назад/вперёд» (этап 6, US5). Ни одна не идёт в пакет: у окна нет отмены.
extension CommandCatalog {
    private static let window = ArgumentSpec.flag("window", .int, "Окно: номер из window state; без него — переднее")
    private static let tab = ArgumentSpec.flag("tab", .int, "Вкладка: номер из window state")

    static let windowCommands: [CommandSpec] = [
        .command("window state", "Окна, вкладки, страница каждой, переднее окно", access: .read, stage: 6, example: "mynotion window state"),
        .command("open", "Открыть страницу в окне", access: .write, stage: 6, example: "mynotion open Проекты/Встреча --new-tab",
                 arguments: [.positional("page", .page, "Страница"), .switch("newTab", "В новой вкладке"), .switch("newWindow", "В новом окне"),
                             .flag("block", .block, "Прокрутить к блоку"), .switch("activate", "Вывести окно вперёд")],
                 exclusive: [["newTab", "newWindow"]]),
        .command("tab new", "Новая вкладка", access: .write, stage: 6, example: "mynotion tab new", arguments: [window]),
        .command("tab select", "Выбрать вкладку", access: .write, stage: 6, example: "mynotion tab select --tab 2",
                 arguments: [window, .flag("tab", .int, "Вкладка: номер из window state", required: true)]),
        .command("tab close", "Закрыть вкладку", access: .write, stage: 6, example: "mynotion tab close --tab 2", arguments: [window, tab]),
        .command("tab reopen", "Вернуть закрытую вкладку", access: .write, stage: 6, example: "mynotion tab reopen", arguments: [window]),
        .command("nav back", "Назад", access: .write, stage: 6, example: "mynotion nav back", arguments: [window]),
        .command("nav forward", "Вперёд", access: .write, stage: 6, example: "mynotion nav forward", arguments: [window]),
    ]
}
