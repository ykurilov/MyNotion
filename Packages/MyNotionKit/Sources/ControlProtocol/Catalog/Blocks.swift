import Foundation

/// Блоки, иконки и обложки (этап 3, US2).
extension CommandCatalog {
    /// Виды блоков, которые принимаются на вход (contracts/block-json.md, «Виды»): строки и ячейки таблицы, колонка — внутренние.
    public static let insertableBlockKinds = [
        "paragraph", "heading1", "heading2", "heading3", "quote", "bulletItem", "numberedItem", "checkbox", "toggle", "callout", "code",
        "equation", "divider", "tableOfContents", "pageLink", "image", "file", "video", "bookmark", "table", "columnList", "database",
    ]

    static let blocks: [CommandSpec] = [
        .command("block kinds", "Виды блоков и их свойства", access: .read, stage: 3, example: "mynotion block kinds"),
        .command("block get", "Блок по id", access: .read, stage: 3, example: "mynotion block get 3f2a91c0-…",
                 arguments: [.positional("block", .block, "Блок")]),
        .command("block insert", "Вставить блок на страницу", access: .write, batchable: true, stage: 3,
                 example: "mynotion block insert current --kind checkbox --text 'Купить **молоко**' --last",
                 arguments: [.positional("page", .page, "Страница"), .flag("kind", .choice(insertableBlockKinds), "Вид", required: true),
                             .flag("text", .string, "Текст: Markdown строки"), .flag("rich", .json, "Текст с точной разметкой"),
                             .flag("props", .json, "Свойства вида"), .flag("after", .block, "За блоком"), .switch("first", "В начало"), .switch("last", "В конец"),
                             .flag("inside", .block, "Внутрь контейнера")],
                 exclusive: [["after", "first", "last", "inside"], ["text", "rich"]]),
        .command("block update", "Изменить текст, свойства или вид блока", access: .write, batchable: true, stage: 3,
                 example: "mynotion block update 3f2a91c0-… --kind heading2",
                 arguments: [.positional("block", .block, "Блок"), .flag("text", .string, "Текст: Markdown строки"),
                             .flag("rich", .json, "Текст с точной разметкой"), .flag("props", .json, "Свойства вида"),
                             .flag("kind", .choice(insertableBlockKinds), "Превратить в")],
                 exclusive: [["text", "rich"]], requiresOneOf: [["text", "rich", "props", "kind"]]),
        .command("block move", "Передвинуть блок с вложенными", access: .write, batchable: true, stage: 3,
                 example: "mynotion block move 3f2a91c0-… --first",
                 arguments: [.positional("block", .block, "Блок"), .flag("after", .block, "За блоком"), .switch("first", "В начало"),
                             .switch("last", "В конец")],
                 exclusive: [["after", "first", "last"]], requiresOneOf: [["after", "first", "last"]]),
        blockAction("block indent", "Сдвинуть блок вправо"),
        blockAction("block outdent", "Сдвинуть блок влево"),
        blockAction("block check", "Отметить задачу"),
        blockAction("block uncheck", "Снять отметку задачи"),
        // Свёрнутость — вид на этом Mac, а не текст: отмена пакета её не откатит, поэтому вне пакета.
        blockAction("block expand", "Раскрыть раскрывающийся список (toggle)", batchable: false),
        blockAction("block collapse", "Свернуть раскрывающийся список (toggle)", batchable: false),
        blockAction("block delete", "Удалить блок"),
        .command("block move-to-page", "Перенести блок на другую страницу", access: .write, batchable: true, stage: 3,
                 example: "mynotion block move-to-page 3f2a91c0-… --page Архив",
                 arguments: [.positional("block", .block, "Блок"), .flag("page", .page, "Куда", required: true)]),
        .command("page icon", "Поставить или убрать иконку страницы", access: .write, batchable: true, stage: 3,
                 example: "mynotion page icon current --emoji 🚀",
                 arguments: [.positional("page", .page, "Страница"), .flag("emoji", .string, "Эмодзи"), .switch("remove", "Убрать")],
                 exclusive: [["emoji", "remove"]], requiresOneOf: [["emoji", "remove"]]),
        .command("page cover", "Обложка страницы: из галереи, файл, сдвиг, убрать; --list — галерея", access: .write, batchable: true,
                 stage: 3, example: "mynotion page cover current --gallery gradients_3 --offset 0.4",
                 arguments: [.positional("page", .page, "Страница", required: false), .flag("gallery", .string, "Имя из галереи"),
                             .flag("file", .path, "Картинка"), .switch("remove", "Убрать"), .flag("offset", .number, "Сдвиг 0…1"),
                             .switch("list", "Показать галерею")],
                 exclusive: [["gallery", "file", "remove", "list"]], requiresOneOf: [["gallery", "file", "remove", "list", "offset"]]),
    ]

    private static func blockAction(_ invocation: String, _ summary: String, batchable: Bool = true) -> CommandSpec {
        .command(invocation, summary, access: .write, batchable: batchable, stage: 3, example: "mynotion \(invocation) 3f2a91c0-…",
                 arguments: [.positional("block", .block, "Блок")])
    }
}
