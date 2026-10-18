import Foundation
import NotesCore

/// Страница выгрузки, прочитанная и разобранная, но ещё не записанная в базу.
struct PlannedPage: Sendable {
    /// Путь файла от корня выгрузки без расширения, в одной форме Юникода: по нему находятся ссылки.
    let key: String
    let file: URL
    let isTable: Bool
    var title: String
    var icon: String?
    var blocks: [ParsedBlock] = []
    var simplifications: [NotionSimplification: Int] = [:]
    var parent: Int?
    var children: [Int] = []
}

/// Выгрузка целиком: страницы, верхний уровень и как найти страницу по ссылке.
struct NotionExportPlan {
    var pages: [PlannedPage] = []
    var roots: [Int] = []
    fileprivate var pageByKey: [String: Int] = [:]
    fileprivate var pageByNotionId: [String: Int] = [:]

    /// Ссылка `path` из страницы `source`: путь от папки её файла.
    func page(atPath path: String, from source: Int) -> Int? {
        let folder = pages[source].key.split(separator: "/").dropLast().map(String.init)
        var components = folder
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(String(part))
            }
        }
        guard let last = components.popLast() else { return nil }
        components.append(NotionExportReader.stem(of: last))
        if let index = pageByKey[NotionExportReader.normalized(components.joined(separator: "/"))] { return index }
        return NotionExportReader.notionId(in: last).flatMap { pageByNotionId[$0] }
    }

    /// Адрес notion.so с id страницы из выгрузки.
    func page(at url: URL) -> Int? {
        guard let host = url.host?.lowercased(), host.hasSuffix("notion.so") || host.hasSuffix("notion.site") else { return nil }
        return NotionExportReader.notionId(in: url.path).flatMap { pageByNotionId[$0] }
    }
}

/// Обход папки выгрузки: файлы `Название <32 hex>.md` и `.csv` — страницы, папка рядом с тем же названием — их подстраницы.
/// Notion 7 пишет хвост id только у файлов, Notion постарше — и у папок; наша выгрузка — ни у тех, ни у других.
/// Папка без своей страницы (обёртка «Private & Shared», корень выгрузки) прозрачна: её страницы — уровнем выше.
struct NotionExportReader {
    func read(_ root: URL, progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> NotionExportPlan {
        var plan = NotionExportPlan()
        plan.roots = try readFolder(root, relative: [], parent: nil, into: &plan)
        guard !plan.pages.isEmpty else { throw NotionImportError.notAnExport }
        try parseContents(of: &plan, progress: progress)
        orderChildrenByLinks(in: &plan)
        return plan
    }

    // MARK: Дерево из путей

    private func readFolder(_ folder: URL, relative: [String], parent: Int?, into plan: inout NotionExportPlan) throws -> [Int] {
        try Task.checkCancellation()
        let entries: [URL]
        do { entries = try NotionExportUnpacker.visibleEntries(of: folder) } catch {
            throw NotionImportError.cannotRead(error.localizedDescription)
        }
        var files: [URL] = []
        var folders: [String: URL] = [:]
        for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                folders[Self.normalized(entry.lastPathComponent)] = entry
            } else {
                files.append(entry)
            }
        }

        // У базы данных Notion два файла: вид `Задачи <id>.csv` и полная таблица `Задачи <id>_all.csv`. Берётся полная.
        var pageFiles: [(stem: String, file: URL, isTable: Bool)] = []
        var tableIndexByStem: [String: Int] = [:]
        for file in files {
            let name = file.lastPathComponent
            switch file.pathExtension.lowercased() {
            case "md": pageFiles.append((Self.stem(of: name), file, false))
            case "csv":
                let stem = Self.stem(of: name)
                if let existing = tableIndexByStem[stem] {
                    if name.lowercased().hasSuffix("_all.csv") { pageFiles[existing].file = file }
                } else {
                    tableIndexByStem[stem] = pageFiles.count
                    pageFiles.append((stem, file, true))
                }
            default: continue
            }
        }
        let titleCounts = Dictionary(pageFiles.map { (Self.title(fromStem: $0.stem), 1) }, uniquingKeysWith: +)

        var result: [Int] = []
        var usedFolders: Set<String> = []
        for (stem, file, isTable) in pageFiles {
            let title = Self.title(fromStem: stem)
            let index = plan.pages.count
            let key = Self.normalized((relative + [stem]).joined(separator: "/"))
            plan.pages.append(PlannedPage(key: key, file: file, isTable: isTable, title: title, parent: parent))
            plan.pageByKey[key] = index
            if let id = Self.notionId(in: stem) { plan.pageByNotionId[id] = index }
            result.append(index)

            let exact = Self.normalized(stem)
            let byTitle = Self.normalized(title)
            let folderName = folders[exact] != nil ? exact : (titleCounts[title] == 1 && folders[byTitle] != nil ? byTitle : nil)
            if let folderName, let subfolder = folders[folderName], !usedFolders.contains(folderName) {
                usedFolders.insert(folderName)
                plan.pages[index].children = try readFolder(subfolder, relative: relative + [subfolder.lastPathComponent],
                                                            parent: index, into: &plan)
            }
        }
        for (name, subfolder) in folders.sorted(by: { $0.key < $1.key }) where !usedFolders.contains(name) {
            result += try readFolder(subfolder, relative: relative + [subfolder.lastPathComponent], parent: parent, into: &plan)
        }
        return result
    }

    // MARK: Содержимое

    /// Разбор страниц параллельно: файлы независимы, а на тысячах страниц это главное время чтения.
    private func parseContents(of plan: inout NotionExportPlan, progress: (@Sendable (Int, Int) -> Void)?) throws {
        let total = plan.pages.count
        let pages = plan.pages
        let results = ParsedPages(count: total)
        DispatchQueue.concurrentPerform(iterations: total) { index in
            let finished = results.store(Result { try Self.parse(pages[index]) }, at: index)
            if finished % 50 == 0 || finished == total { progress?(finished, total) }
        }
        for index in 0..<total {
            plan.pages[index] = try results.result(at: index).get()
        }
        try Task.checkCancellation()
    }

    private static func parse(_ page: PlannedPage) throws -> PlannedPage {
        var page = page
        let text: String
        do {
            text = try String(contentsOf: page.file, encoding: .utf8)
        } catch {
            throw NotionImportError.cannotRead("файл «\(page.file.lastPathComponent)» не читается")
        }
        if page.isTable {
            page.blocks = NotionCSV.paragraphs(text).map { ParsedBlock(kind: .paragraph, text: InlineText($0)) }
            page.simplifications = [.table: 1]
        } else {
            let parsed = NotionMarkdownParser().parse(text)
            if let title = parsed.title { page.title = title }
            page.icon = parsed.icon
            page.blocks = parsed.blocks
            page.simplifications = parsed.simplifications
        }
        return page
    }

    /// Подстраницы — в порядке ссылок на них в родителе; без ссылки — в конце, по имени файла.
    private func orderChildrenByLinks(in plan: inout NotionExportPlan) {
        for index in plan.pages.indices where !plan.pages[index].children.isEmpty {
            let children = plan.pages[index].children
            let childSet = Set(children)
            var ordered: [Int] = []
            for block in plan.pages[index].blocks {
                guard let target = Self.linkedPage(block, from: index, in: plan), childSet.contains(target), !ordered.contains(target)
                else { continue }
                ordered.append(target)
            }
            plan.pages[index].children = ordered + children.filter { !ordered.contains($0) }
        }
    }

    static func linkedPage(_ block: ParsedBlock, from source: Int, in plan: NotionExportPlan) -> Int? {
        if let path = block.pagePath { return plan.page(atPath: path, from: source) }
        if let url = block.standaloneURL { return plan.page(at: url) }
        return nil
    }

    // MARK: Имена

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
    }

    /// Имя файла без расширения и без `_all` у полной таблицы.
    static func stem(of fileName: String) -> String {
        var stem = (fileName as NSString).deletingPathExtension
        if (fileName as NSString).pathExtension.lowercased() == "csv", stem.lowercased().hasSuffix("_all") { stem.removeLast(4) }
        return stem
    }

    /// `Проекты 1f2a…f701` → `Проекты`.
    static func title(fromStem stem: String) -> String {
        guard notionId(in: stem) != nil, stem.count > 33, stem.dropLast(32).last == " " else { return stem }
        return String(stem.dropLast(33))
    }

    /// 32 hex в конце (`Проекты 1f2a…`, `MyNotion-2a3b…`) — id страницы Notion.
    static func notionId(in text: String) -> String? {
        let tail = text.suffix(32)
        guard tail.count == 32, tail.allSatisfy(\.isHexDigit) else { return nil }
        let before = text.dropLast(32).last
        guard before == nil || before == " " || before == "-" || before == "/" else { return nil }
        return tail.lowercased()
    }
}

/// Итоги параллельного разбора и сколько страниц уже готово (для хода работы).
private final class ParsedPages: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<PlannedPage, any Error>?]
    private var finished = 0

    init(count: Int) { results = Array(repeating: nil, count: count) }

    /// Сколько готово вместе с этой.
    func store(_ result: Result<PlannedPage, any Error>, at index: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        results[index] = result
        finished += 1
        return finished
    }

    func result(at index: Int) -> Result<PlannedPage, any Error> {
        lock.lock()
        defer { lock.unlock() }
        return results[index]!
    }
}
