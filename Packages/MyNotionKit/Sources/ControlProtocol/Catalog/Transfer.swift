import Foundation

/// Импорт, выгрузка, синхронизация (этап 7, US6).
extension CommandCatalog {
    static let transfer: [CommandSpec] = [
        .command("import notion", "Импорт выгрузки Notion: архив .zip или папка; ход — строками progress", access: .write, stage: 7,
                 example: "mynotion import notion ~/Downloads/Export.zip --parent Архив",
                 arguments: [.positional("source", .path, "Архив .zip или папка"), .flag("parent", .page, "Куда")], isLong: true),
        .command("export page", "Выгрузить страницу в Markdown", access: .read, stage: 7,
                 example: "mynotion export page Проекты --to ~/Desktop/выгрузка",
                 arguments: [.positional("page", .page, "Страница"), .flag("to", .path, "Папка", required: true),
                             .switch("noChildren", "Без подстраниц")], isLong: true),
        .command("export all", "Выгрузить всю библиотеку", access: .read, stage: 7, example: "mynotion export all --to ~/Desktop/выгрузка",
                 arguments: [.flag("to", .path, "Папка", required: true)], isLong: true),
        .command("sync status", "Состояние синхронизации", access: .read, stage: 7, example: "mynotion sync status"),
        .command("sync now", "Синхронизировать сейчас", access: .write, stage: 7, example: "mynotion sync now"),
    ]
}
