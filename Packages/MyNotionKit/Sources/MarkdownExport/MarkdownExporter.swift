import Foundation
import NotesCore

/// Сколько страниц уже записано (для полосы хода работы).
public struct MarkdownExportProgress: Sendable, Equatable {
    public var pagesDone: Int
    public var pagesTotal: Int
}

public struct MarkdownExportResult: Sendable, Equatable {
    /// Готовая папка `MyNotion-выгрузка-<ГГГГ-ММ-ДД>`.
    public var folder: URL
    public var pageCount: Int
    public var blockCount: Int
}

public enum MarkdownExportError: Error, LocalizedError, Equatable {
    case destinationMissing(String)
    case cannotRead(String)
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .destinationMissing(let path): "Папка «\(path)» не найдена. Выберите другую папку для выгрузки."
        case .cannotRead(let reason): "Не удалось прочитать записи: \(reason). Выгрузка не создана."
        case .cannotWrite(let reason): "Не удалось записать выгрузку: \(reason). Выгрузка не создана, прежние файлы не тронуты."
        }
    }
}

/// Выгрузка всех записей в папку Markdown (FR-017, contracts/files-import-export.md).
/// Обходит дерево страниц, имена файлов и ссылки между ними считает здесь, текст страницы пишет `MarkdownBlockWriter`.
/// Пишет сначала во временную папку рядом и только в конце переименовывает её: частичной выгрузки не бывает.
/// Вызывается из фоновой задачи; отмена задачи прерывает выгрузку и убирает временную папку.
public struct MarkdownExporter: Sendable {
    private let store: NotesStore
    private let now: @Sendable () -> Date
    private let blockWriter = MarkdownBlockWriter()
    /// Запись одного файла; подменяется в тестах, чтобы проверить, что случается при ошибке диска.
    var writeFile: @Sendable (Data, URL) throws -> Void = { data, url in try data.write(to: url) }

    public init(store: NotesStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func export(into parentFolder: URL, progress: (@Sendable (MarkdownExportProgress) -> Void)? = nil) throws -> MarkdownExportResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MarkdownExportError.destinationMissing(parentFolder.path)
        }

        let plan: ExportPlan
        do { plan = try ExportPlan(pages: store.pageOutline()) } catch { throw MarkdownExportError.cannotRead(error.localizedDescription) }

        // Рядом с будущей папкой, на том же диске: переименование мгновенное и целиком. Имя скрытое — Finder его не показывает.
        let draft = parentFolder.appendingPathComponent(".MyNotion-выгрузка-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: false)
        } catch {
            throw MarkdownExportError.cannotWrite(error.localizedDescription)
        }
        do {
            let blockCount = try writePages(of: plan, into: draft, progress: progress)
            let folder = try publish(draft, in: parentFolder)
            return MarkdownExportResult(folder: folder, pageCount: plan.orderedPages.count, blockCount: blockCount)
        } catch {
            try? FileManager.default.removeItem(at: draft)
            switch error {
            case is CancellationError, is MarkdownExportError: throw error
            default: throw MarkdownExportError.cannotWrite(error.localizedDescription)
            }
        }
    }

    // MARK: Запись

    private func writePages(of plan: ExportPlan, into draft: URL, progress: (@Sendable (MarkdownExportProgress) -> Void)?) throws -> Int {
        var createdFolders: Set<[String]> = []
        var blockCount = 0
        for (index, page) in plan.orderedPages.enumerated() {
            try Task.checkCancellation()
            let content: PageContent?
            do { content = try store.pageContent(page.id) } catch { throw MarkdownExportError.cannotRead(error.localizedDescription) }
            if let content, let location = plan.location(of: page.id) {
                let text = markdown(for: content, at: location, in: plan)
                if !createdFolders.contains(location.folder) {
                    let folder = location.folder.reduce(draft) { $0.appendingPathComponent($1, isDirectory: true) }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    createdFolders.insert(location.folder)
                }
                let file = (location.folder + [location.fileName]).reduce(draft) { $0.appendingPathComponent($1) }
                try writeFile(Data(text.utf8), file)
                blockCount += content.blocks.count
            }
            progress?(MarkdownExportProgress(pagesDone: index + 1, pagesTotal: plan.orderedPages.count))
        }
        return blockCount
    }

    private func markdown(for content: PageContent, at location: ExportPlan.Location, in plan: ExportPlan) -> String {
        let titleLine = "# " + ([content.page.icon].compactMap { $0 } + [blockWriter.escapedTitle(content.page.displayTitle)])
            .joined(separator: " ")
        let body = blockWriter.markdown(for: content.blocks) { plan.linkTarget(for: $0, from: location) }
        return body.isEmpty ? titleLine + "\n" : titleLine + "\n\n" + body
    }

    /// Готовая папка получает своё имя; если такая уже есть (вторая выгрузка за день), рядом — с ` (2)`. Прежнее не трогается.
    private func publish(_ draft: URL, in parentFolder: URL) throws -> URL {
        let baseName = "MyNotion-выгрузка-\(Self.dateStamp(now()))"
        var name = baseName
        var number = 2
        while FileManager.default.fileExists(atPath: parentFolder.appendingPathComponent(name).path) {
            name = "\(baseName) (\(number))"
            number += 1
        }
        let destination = parentFolder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.moveItem(at: draft, to: destination)
        return destination
    }

    private static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Куда ляжет каждая страница: папка и имя файла. Страницы в корзине в план не попадают.
private struct ExportPlan {
    struct Location {
        /// Папки от корня выгрузки.
        var folder: [String]
        var fileName: String
        var components: [String] { folder + [fileName] }
    }

    private(set) var orderedPages: [Page] = []
    private var locations: [UUID: Location] = [:]
    private var titles: [UUID: String] = [:]
    private var titlesOfTrashedPages: [UUID: String] = [:]

    init(pages: [Page]) {
        let tree = PageTreeSnapshot(allPages: pages)
        for page in pages where tree.page(page.id) == nil { titlesOfTrashedPages[page.id] = page.displayTitle }
        place(children: tree.children(of: nil), folder: [], in: tree)
    }

    private mutating func place(children: [Page], folder: [String], in tree: PageTreeSnapshot) {
        let names = ExportFileNames.uniqueNames(forTitles: children.map(\.title))
        for (page, name) in zip(children, names) {
            orderedPages.append(page)
            titles[page.id] = page.displayTitle
            locations[page.id] = Location(folder: folder, fileName: name + ".md")
            let subpages = tree.children(of: page.id)
            if !subpages.isEmpty { place(children: subpages, folder: folder + [name], in: tree) }
        }
    }

    func location(of pageId: UUID) -> Location? { locations[pageId] }

    /// Ссылка из страницы `source` на `pageId`: путь файла от папки, где лежит `source`.
    func linkTarget(for pageId: UUID, from source: Location) -> PageLinkTarget? {
        if let target = locations[pageId] {
            var common = 0
            while common < source.folder.count, common < target.folder.count, source.folder[common] == target.folder[common] { common += 1 }
            let path = Array(repeating: "..", count: source.folder.count - common) + target.components[common...]
            return PageLinkTarget(title: titles[pageId] ?? Page.untitledTitle, path: path.joined(separator: "/"))
        }
        return titlesOfTrashedPages[pageId].map { PageLinkTarget(title: $0, path: nil) }
    }
}
