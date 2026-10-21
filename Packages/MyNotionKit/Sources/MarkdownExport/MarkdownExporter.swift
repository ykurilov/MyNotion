import Foundation
import GRDB
import NotesCore
import UniformTypeIdentifiers

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
    /// Файлы, которые ещё не скачались на этот Mac: вместо них в выгрузке строка «[файл не скачан: имя]».
    public var missingFileCount: Int = 0

    /// Итог выгрузки о нескачанных файлах (contracts/markdown-and-notion.md, «Файлы»).
    public static func missingFilesMessage(count: Int) -> String {
        "Не выгружено файлов: \(count) — они ещё не скачались с сервера"
    }
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
    /// Копия файла на этом Mac по id; `nil` — файл ещё не скачан.
    private let attachmentFile: @Sendable (UUID) -> URL?
    private let blockWriter = MarkdownBlockWriter()
    /// Запись одного файла; подменяется в тестах, чтобы проверить, что случается при ошибке диска.
    var writeFile: @Sendable (Data, URL) throws -> Void = { data, url in try data.write(to: url) }

    public init(store: NotesStore, now: @escaping @Sendable () -> Date = { Date() },
                attachmentFile: @escaping @Sendable (UUID) -> URL? = { _ in nil }) {
        self.store = store
        self.now = now
        self.attachmentFile = attachmentFile
    }

    public func export(into parentFolder: URL, progress: (@Sendable (MarkdownExportProgress) -> Void)? = nil) throws -> MarkdownExportResult {
        try export(root: nil, into: parentFolder, baseName: "MyNotion-выгрузка", progress: progress)
    }

    /// «Выгрузить базу» (меню «•••» страницы-базы): CSV, папка строк и схема одной базы — в новой папке
    /// `<База>-выгрузка-<ГГГГ-ММ-ДД>`. Связи на строки вне неё — названиями, без пути.
    public func exportDatabase(_ databaseId: UUID, into parentFolder: URL,
                               progress: (@Sendable (MarkdownExportProgress) -> Void)? = nil) throws -> MarkdownExportResult {
        let title: String
        do { title = try store.pageContent(databaseId)?.page.title ?? "" } catch { throw MarkdownExportError.cannotRead(error.localizedDescription) }
        return try export(root: databaseId, into: parentFolder, baseName: ExportFileNames.baseName(forTitle: title) + "-выгрузка",
                          progress: progress)
    }

    private func export(root: UUID?, into parentFolder: URL, baseName: String,
                        progress: (@Sendable (MarkdownExportProgress) -> Void)?) throws -> MarkdownExportResult {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parentFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MarkdownExportError.destinationMissing(parentFolder.path)
        }

        let plan: ExportPlan
        do {
            let databases = try store.database.dbWriter.read { db in
                Set(try String.fetchAll(db, sql: "SELECT pageId FROM db_database").compactMap(UUID.init(uuidString:)))
            }
            plan = try ExportPlan(pages: store.pageOutline(), databases: databases, root: root)
        } catch {
            throw MarkdownExportError.cannotRead(error.localizedDescription)
        }

        // Рядом с будущей папкой, на том же диске: переименование мгновенное и целиком. Имя скрытое — Finder его не показывает.
        let draft = parentFolder.appendingPathComponent(".MyNotion-выгрузка-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: false)
        } catch {
            throw MarkdownExportError.cannotWrite(error.localizedDescription)
        }
        do {
            let (blockCount, missingFiles) = try writePages(of: plan, into: draft, progress: progress)
            let folder = try publish(draft, in: parentFolder, baseName: baseName)
            return MarkdownExportResult(folder: folder, pageCount: plan.orderedPages.count, blockCount: blockCount,
                                        missingFileCount: missingFiles)
        } catch {
            try? FileManager.default.removeItem(at: draft)
            switch error {
            case is CancellationError, is MarkdownExportError: throw error
            default: throw MarkdownExportError.cannotWrite(error.localizedDescription)
            }
        }
    }

    // MARK: Запись

    private func writePages(of plan: ExportPlan, into draft: URL,
                            progress: (@Sendable (MarkdownExportProgress) -> Void)?) throws -> (blocks: Int, missingFiles: Int) {
        var createdFolders: Set<[String]> = []
        var blockCount = 0
        var missingFiles = 0
        func createFolder(_ components: [String]) throws {
            guard !createdFolders.contains(components) else { return }
            let folder = components.reduce(draft) { $0.appendingPathComponent($1, isDirectory: true) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            createdFolders.insert(components)
        }
        // Базы, чьи строки ещё пишутся: снимок читается один раз, на странице-базе (она раньше своих строк).
        var databases: [UUID: (snapshot: DatabaseExportSnapshot, values: DatabaseValueText)] = [:]
        for (index, page) in plan.orderedPages.enumerated() {
            try Task.checkCancellation()
            if plan.isDatabase(page.id), let location = plan.location(of: page.id) {
                let snapshot: DatabaseExportSnapshot?
                do { snapshot = try DatabaseExportSnapshot.read(page.id, from: store) } catch {
                    throw MarkdownExportError.cannotRead(error.localizedDescription)
                }
                if let snapshot {
                    try createFolder(location.folder)
                    try writeDatabase(snapshot, at: location, in: plan, into: draft)
                    databases[page.id] = (snapshot, DatabaseValueText(snapshot: snapshot))
                }
                progress?(MarkdownExportProgress(pagesDone: index + 1, pagesTotal: plan.orderedPages.count))
                continue
            }
            let content: PageContent?
            do { content = try store.pageContent(page.id) } catch { throw MarkdownExportError.cannotRead(error.localizedDescription) }
            if let content, let location = plan.location(of: page.id) {
                let (attachmentPaths, coverName, missing) = try copyAttachments(of: content, at: location, in: plan, into: draft,
                                                                                createFolder: createFolder)
                missingFiles += missing
                // Строка базы: под названием — «Свойство: значение», как у Notion.
                let propertyLines = page.parentId.flatMap { databases[$0] }.map { database in
                    RowMarkdownWriter.propertyLines(of: content.page, in: database.snapshot, values: database.values) { target in
                        plan.linkTarget(for: target, from: location)?.path
                    }
                } ?? []
                let text = markdown(for: content, at: location, in: plan, attachmentPaths: attachmentPaths, coverFileName: coverName,
                                    propertyLines: propertyLines)
                try createFolder(location.folder)
                let file = (location.folder + [location.fileName]).reduce(draft) { $0.appendingPathComponent($1) }
                try writeFile(Data(text.utf8), file)
                blockCount += content.blocks.count
            }
            progress?(MarkdownExportProgress(pagesDone: index + 1, pagesTotal: plan.orderedPages.count))
        }
        return (blockCount, missingFiles)
    }

    /// База: `Задачи.csv` и схема `Задачи.mynotion-database.json` рядом; строки — файлами в `Задачи/` (пишет обход страниц).
    private func writeDatabase(_ snapshot: DatabaseExportSnapshot, at location: ExportPlan.Location, in plan: ExportPlan, into draft: URL) throws {
        let folder = location.folder.reduce(draft) { $0.appendingPathComponent($1, isDirectory: true) }
        let csv = DatabaseCSVWriter.csv(snapshot) { target in plan.linkTarget(for: target, from: location)?.path }
        try writeFile(Data(csv.utf8), folder.appendingPathComponent(location.fileName))
        let schema = DatabaseSchemaFile(snapshot, rowFile: { row in
            plan.location(of: row.id).map { Array($0.components.dropFirst(location.folder.count)).joined(separator: "/") } ?? ""
        }, relationTarget: { target in plan.linkTarget(for: target, from: location)?.path })
        try writeFile(try schema.encoded(), folder.appendingPathComponent(location.stem + DatabaseSchemaFile.fileSuffix))
    }

    /// Копии файлов страницы — в её папку `Название/`, рядом с подстраницами; совпадающие имена — с « (2)».
    /// Своя картинка обложки — последней, под именем «Обложка.<расширение>».
    /// Возвращает пути копий от файла страницы, имя копии обложки и сколько файлов ещё не скачано.
    private func copyAttachments(of content: PageContent, at location: ExportPlan.Location, in plan: ExportPlan, into draft: URL,
                                 createFolder: ([String]) throws -> Void) throws -> (paths: [UUID: String], coverName: String?, missing: Int) {
        let refs = content.blocks.compactMap { block -> AttachmentRef? in
            [.image, .file, .video].contains(block.kind) ? block.props.attachment : nil
        }
        // Обложка ролика, картинка и значок закладки: без них карточка всё равно видна, «Обновить» скачает их заново —
        // поэтому их нехватка в «Не выгружено файлов» не считается.
        let decorations = content.blocks.flatMap { block -> [AttachmentRef] in
            switch block.kind {
            case .video: [block.props.poster].compactMap { $0 }
            case .bookmark: [block.props.image, block.props.iconAttachment].compactMap { $0 }
            default: []
            }
        }
        let cover = content.page.cover?.attachment
        guard !refs.isEmpty || !decorations.isEmpty || cover != nil else { return ([:], nil, 0) }
        let pageFolder = location.folder + [location.stem]
        var taken = plan.entryNames(inFolder: pageFolder)
        var paths: [UUID: String] = [:]
        var missing = 0
        let mainCount = refs.count
        for (position, ref) in (refs + decorations).enumerated() where paths[ref.id] == nil {
            guard let source = attachmentFile(ref.id) else {
                if position < mainCount { missing += 1 }
                continue
            }
            let name = ExportFileNames.uniqueFileName(ref.name, taken: &taken)
            try createFolder(pageFolder)
            let destination = pageFolder.reduce(draft) { $0.appendingPathComponent($1, isDirectory: true) }.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: destination)
            paths[ref.id] = location.stem + "/" + name
        }
        var coverName: String?
        if let cover {
            if let source = attachmentFile(cover.id) {
                coverName = ExportFileNames.coverFileName(extension: Self.fileExtension(of: cover), taken: &taken)
                try createFolder(pageFolder)
                let destination = pageFolder.reduce(draft) { $0.appendingPathComponent($1, isDirectory: true) }.appendingPathComponent(coverName!)
                try FileManager.default.copyItem(at: source, to: destination)
            } else {
                missing += 1
            }
        }
        return (paths, coverName, missing)
    }

    /// Расширение копии обложки: как у исходного файла, без него — по типу файла.
    private static func fileExtension(of ref: AttachmentRef) -> String {
        let own = (ref.name as NSString).pathExtension
        if !own.isEmpty { return own }
        return UTType(ref.contentType)?.preferredFilenameExtension ?? ""
    }

    private func markdown(for content: PageContent, at location: ExportPlan.Location, in plan: ExportPlan,
                          attachmentPaths: [UUID: String], coverFileName: String?, propertyLines: [String] = []) -> String {
        var titleLine = "# " + ([content.page.icon].compactMap { $0 } + [blockWriter.escapedTitle(content.page.displayTitle)])
            .joined(separator: " ")
        if let cover = CoverComment.line(for: content.page.cover, fileName: coverFileName) { titleLine += "\n" + cover }
        let body = blockWriter.markdown(for: content.blocks, resolveLink: { plan.linkTarget(for: $0, from: location) },
                                        resolveAttachment: { attachmentPaths[$0.id] })
        if !propertyLines.isEmpty { titleLine += "\n\n" + propertyLines.joined(separator: "\n") }
        return body.isEmpty ? titleLine + "\n" : titleLine + "\n\n" + body
    }

    /// Готовая папка получает своё имя; если такая уже есть (вторая выгрузка за день), рядом — с ` (2)`. Прежнее не трогается.
    private func publish(_ draft: URL, in parentFolder: URL, baseName: String) throws -> URL {
        let baseName = "\(baseName)-\(Self.dateStamp(now()))"
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
        /// Имя без `.md` (у базы — без `.csv`) — оно же имя папки подстраниц и файлов страницы.
        var stem: String { (fileName as NSString).deletingPathExtension }
    }

    private(set) var orderedPages: [Page] = []
    private var locations: [UUID: Location] = [:]
    private var titles: [UUID: String] = [:]
    private var icons: [UUID: String] = [:]
    private var titlesOfTrashedPages: [UUID: String] = [:]
    private let databases: Set<UUID>
    /// Папка шаблонов строк в папке базы.
    static let templatesFolder = "Шаблоны"

    /// `databases` — страницы-базы: вместо `.md` у них `.csv`, шаблоны строк — в `Шаблоны/`. `root` — выгрузить только эту ветку.
    init(pages: [Page], databases: Set<UUID> = [], root: UUID? = nil) {
        self.databases = databases
        let tree = PageTreeSnapshot(allPages: pages)
        for page in pages where tree.page(page.id) == nil { titlesOfTrashedPages[page.id] = page.displayTitle }
        place(children: root.map { tree.page($0).map { [$0] } ?? [] } ?? tree.children(of: nil), folder: [], in: tree)
        if let root {
            // Страницы вне ветки — названиями, без пути (как страницы в корзине).
            for page in pages where locations[page.id] == nil && page.id != root { titlesOfTrashedPages[page.id] = page.displayTitle }
        }
    }

    private mutating func place(children: [Page], folder: [String], in tree: PageTreeSnapshot, reserved: Set<String> = []) {
        let names = ExportFileNames.uniqueNames(forTitles: children.map(\.title), reserved: reserved)
        for (page, name) in zip(children, names) {
            orderedPages.append(page)
            titles[page.id] = page.displayTitle
            icons[page.id] = page.icon
            let isDatabase = databases.contains(page.id)
            locations[page.id] = Location(folder: folder, fileName: name + (isDatabase ? ".csv" : ".md"))
            let subpages = tree.children(of: page.id)
            if isDatabase {
                let rows = subpages.filter { !$0.isTemplate }
                let templates = subpages.filter(\.isTemplate)
                if !rows.isEmpty { place(children: rows, folder: folder + [name], in: tree, reserved: [Self.templatesFolder]) }
                if !templates.isEmpty { place(children: templates, folder: folder + [name, Self.templatesFolder], in: tree) }
            } else if !subpages.isEmpty {
                place(children: subpages, folder: folder + [name], in: tree)
            }
        }
    }

    func location(of pageId: UUID) -> Location? { locations[pageId] }

    func isDatabase(_ pageId: UUID) -> Bool { databases.contains(pageId) }

    /// Имена, уже занятые в папке подстраницами: их файлы `.md` и папки.
    func entryNames(inFolder folder: [String]) -> Set<String> {
        Set(locations.values.filter { $0.folder == folder }.flatMap { [$0.fileName, $0.stem] }.map(ExportFileNames.key))
    }

    /// Ссылка из страницы `source` на `pageId`: путь файла от папки, где лежит `source`.
    func linkTarget(for pageId: UUID, from source: Location) -> PageLinkTarget? {
        if let target = locations[pageId] {
            var common = 0
            while common < source.folder.count, common < target.folder.count, source.folder[common] == target.folder[common] { common += 1 }
            let path = Array(repeating: "..", count: source.folder.count - common) + target.components[common...]
            return PageLinkTarget(title: titles[pageId] ?? Page.untitledTitle, path: path.joined(separator: "/"), icon: icons[pageId])
        }
        return titlesOfTrashedPages[pageId].map { PageLinkTarget(title: $0, path: nil) }
    }
}
