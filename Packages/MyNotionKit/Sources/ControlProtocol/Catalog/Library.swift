import Foundation

/// Поиск, избранное, недавние, шаблоны, история, вложения (этап 5, US4).
extension CommandCatalog {
    private static let page = ArgumentSpec.positional("page", .page, "Страница")

    static let library: [CommandSpec] = [
        .command("search", "Поиск по названиям и тексту: id, название, путь, отрывок, тип", access: .read, stage: 5,
                 example: "mynotion search 'план запуска' --limit 10",
                 arguments: [.positional("query", .string, "Слова")]),
        .command("favorites list", "Избранное по порядку", access: .read, stage: 5, example: "mynotion favorites list"),
        .command("favorites add", "Добавить страницу в избранное", access: .write, batchable: true, stage: 5,
                 example: "mynotion favorites add current", arguments: [page]),
        .command("favorites remove", "Убрать страницу из избранного", access: .write, batchable: true, stage: 5,
                 example: "mynotion favorites remove current", arguments: [page]),
        .command("favorites move", "Передвинуть страницу в избранном", access: .write, batchable: true, stage: 5,
                 example: "mynotion favorites move current --index 0",
                 arguments: [page, .flag("index", .int, "Место с нуля", required: true)]),
        .command("recents", "Недавние страницы", access: .read, stage: 5, example: "mynotion recents --limit 10"),
        .command("template list", "Страницы-шаблоны", access: .read, stage: 5, example: "mynotion template list"),
        .command("template mark", "Сделать страницу шаблоном", access: .write, batchable: true, stage: 5,
                 example: "mynotion template mark 'Шаблон встречи'", arguments: [page]),
        .command("template unmark", "Страница больше не шаблон", access: .write, batchable: true, stage: 5,
                 example: "mynotion template unmark 'Шаблон встречи'", arguments: [page]),
        // Список сперва снимает неснятую правку версией — это запись, под замком записи.
        .command("history list", "Версии страницы: время, Mac, сводка, agent", access: .write, stage: 5,
                 example: "mynotion history list current", arguments: [page]),
        .command("history show", "Содержимое версии", access: .read, stage: 5, example: "mynotion history show current 0193…",
                 arguments: [page, .positional("version", .version, "Версия"),
                             .flag("format", .choice(["markdown", "json"]), "Вид ответа", default: "markdown")]),
        .command("history restore", "Восстановить версию (текущий вид сохранится версией)", access: .write, stage: 5,
                 example: "mynotion history restore current 0193…", arguments: [page, .positional("version", .version, "Версия")]),
        .command("attachment add", "Вложить файл: блоком на страницу или в ячейку «Файлы» строки", access: .write, batchable: true, stage: 5,
                 example: "mynotion attachment add current --file ~/Desktop/схема.png --as image",
                 arguments: [.positional("page", .page, "Страница или база"), .positional("row", .row, "Строка (для ячейки)", required: false),
                             .positional("property", .property, "Свойство «Файлы» (для ячейки)", required: false),
                             .flag("file", .path, "Файл", required: true), .flag("after", .block, "За каким блоком"),
                             .flag("as", .choice(["image", "file", "video"]), "Каким блоком")]),
        .command("attachment list", "Вложения страницы", access: .read, stage: 5, example: "mynotion attachment list current",
                 arguments: [page]),
        .command("attachment get", "Сохранить копию вложения", access: .read, stage: 5,
                 example: "mynotion attachment get 0193… --to ~/Desktop",
                 arguments: [.positional("attachment", .attachment, "Вложение"), .flag("to", .path, "Куда", required: true)]),
    ]
}
