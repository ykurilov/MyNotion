import Foundation

/// Выгрузка Notion для замера импорта (T086, SC-010): 1 000 страниц в три уровня (10 × 9 × 10), около 150 блоков
/// на странице (≈147 000 всего) — тяжелее эталонной базы. Имена — как у Notion 7: файл `Название <32 hex>.md`, папка подстраниц `Название/`.
/// В каждой странице все поддерживаемые блоки, на каждой десятой — таблица, цитата, код и картинка.
public struct SampleNotionExportGenerator: Sendable {
    public static let pageCount = 1_000
    /// Строк Markdown на страницу; списки в строке — несколько блоков, поэтому блоков больше.
    public static let blocksPerPage = 100

    public init() {}

    /// Записать выгрузку в пустую или несуществующую папку `folder`.
    public func generate(into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var number = 0
        func nextPage() -> (title: String, file: String) {
            number += 1
            let title = "Страница \(number)"
            return (title, "\(title) \(String(format: "%032x", number)).md")
        }
        for _ in 0..<10 {
            let top = nextPage()
            let topFolder = folder.appendingPathComponent(top.title, isDirectory: true)
            var topChildren: [(String, String)] = []
            for _ in 0..<9 {
                let middle = nextPage()
                let middleFolder = topFolder.appendingPathComponent(middle.title, isDirectory: true)
                let leaves = (0..<10).map { _ in nextPage() }
                try FileManager.default.createDirectory(at: middleFolder, withIntermediateDirectories: true)
                for leaf in leaves {
                    try write(page: leaf, children: [], number: number, to: middleFolder)
                }
                try write(page: middle, children: leaves.map { (middle.title + "/" + $0.file, $0.title) }, number: number,
                          to: topFolder)
                topChildren.append((top.title + "/" + middle.file, middle.title))
            }
            try write(page: top, children: topChildren, number: number, to: folder)
        }
    }

    private func write(page: (title: String, file: String), children: [(path: String, title: String)], number: Int, to folder: URL) throws {
        var lines = ["# \(page.title)", ""]
        let links = children.map { "[\($0.title)](\(Self.encoded($0.path)))" }
        // Ссылки на подстраницы — часть блоков страницы.
        let contentBlocks = Self.blocksPerPage - links.count
        var written = 0
        var section = 0
        while written < contentBlocks {
            section += 1
            let chunk = Self.section(section, of: page.title, extended: number % 10 == 0 && section == 1)
            for block in chunk.prefix(contentBlocks - written) {
                lines.append(block)
                lines.append("")
            }
            written += min(chunk.count, contentBlocks - written)
        }
        for link in links {
            lines.append(link)
            lines.append("")
        }
        try Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent(page.file))
    }

    /// Двадцать блоков: заголовки, абзацы с оформлением и переносом, списки с вложенностью, чекбоксы.
    private static func section(_ index: Int, of title: String, extended: Bool) -> [String] {
        var blocks = [
            "## Раздел \(index)",
            "Обычный абзац страницы «\(title)» с **жирным**, *курсивом*, ~~зачёркнутым~~, `кодом` и [ссылкой](https://example.com/\(index)).",
            "Абзац в две строки: первая\nи вторая после переноса.",
            "### Подраздел \(index)",
            "- Пункт списка\n- Ещё пункт\n    - Вложенный пункт\n        - Третий уровень",
            "1. Первый\n2. Второй\n    1. Вложенный номер",
            "- [ ]  Невыполненная задача\n- [x]  Выполненная задача",
        ]
        if extended {
            blocks += ["> Цитата из книги", "```\nlet answer = 42\n```", "| Имя | Роль |\n| --- | --- |\n| Юрий | автор |",
                       "![схема.png](\(encoded(title))/схема.png)"]
        }
        // Списки выше — несколько блоков в одной строке: добить до двадцати простыми абзацами.
        let counted = blocks.reduce(0) { $0 + $1.components(separatedBy: "\n").filter { !$0.isEmpty && $0 != "```" && !$0.hasPrefix("| ---") }.count }
        for line in 0..<max(0, 20 - counted) {
            blocks.append("Строка \(line + 1) раздела \(index): текст для поиска и прокрутки, немного **оформления** в конце.")
        }
        return blocks
    }

    private static func encoded(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))) ?? path
    }
}
