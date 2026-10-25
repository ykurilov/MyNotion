import Foundation

/// Служебные команды (этап 1): состояние приложения, каталог, пакет.
extension CommandCatalog {
    static let service: [CommandSpec] = [
        .command("app status", "Версия приложения и протокола, путь базы, окна, идёт ли импорт", access: .read, stage: 1,
                 example: "mynotion app status"),
        .command("commands", "Весь каталог команд машинно", access: .read, stage: 1, example: "mynotion commands --json",
                 arguments: [.switch("json", "JSON вместо текста")], runsWithoutApp: true),
        .command("batch", "Несколько изменяющих команд одним шагом: ошибка шага откатывает весь пакет", access: .write, stage: 1,
                 example: #"echo '[{"command":"page.create","args":{"title":"А"}},{"command":"page.rename","args":{"page":"$1.page.id","title":"Б"}}]' | mynotion batch"#,
                 arguments: [.flag("steps", .jsonContent, "Шаги: [{\"command\":…,\"args\":{…}}]; \"$N.путь\" — значение из ответа шага N",
                                   default: "-", flag: "file")]),
    ]
}
