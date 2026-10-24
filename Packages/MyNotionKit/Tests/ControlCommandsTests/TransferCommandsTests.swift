import Attachments
import ControlProtocol
import Foundation
import MarkdownExport
import NotionImport
import Testing
@testable import ControlCommands
@testable import NotesCore
@testable import PageVersions

/// Импорт из меню переносит файлы в хранилище вложений (в приложении — то же расширение в MediaServices).
extension AttachmentStore: NotionAttachmentImporting {}

/// Подставные импорт в окне и синхронизация приложения: записывают, что им сообщили, и отвечают заданным состоянием.
@MainActor
final class RecordingTransferControl: TransferControl {
    var isImporting = false
    var syncState = SyncState(status: .off)
    /// Чем кончится `sync now`: новое состояние или ошибка.
    var syncNowOutcome: Result<SyncState, ControlError>?
    private(set) var syncNowCalls = 0
    private(set) var importStarts = 0
    private(set) var importSteps: [NotionImportProgress] = []
    private(set) var importOutcomes: [Bool] = []
    /// Кнопка «Остановить» карточки импорта.
    private(set) var stopImport: (@MainActor () -> Void)?

    func commandImportDidStart(stop: @escaping @MainActor () -> Void) {
        importStarts += 1
        stopImport = stop
    }

    func commandImport(progress: NotionImportProgress) { importSteps.append(progress) }

    func commandImportDidFinish(_ outcome: Result<NotionImportReport, any Error>) {
        importOutcomes.append((try? outcome.get()) != nil)
    }

    func syncNow() async throws -> SyncState {
        syncNowCalls += 1
        return try (syncNowOutcome ?? .success(syncState)).get()
    }
}

/// Хост на временной базе с подставными импортом в окне и синхронизацией.
@MainActor
final class TransferTestHost: ControlHost {
    let base: TestHost
    let transfer = RecordingTransferControl()

    init() throws {
        base = try TestHost()
    }

    var store: NotesStore { base.store }
    var attachments: AttachmentStore { base.attachments }
    var openDocuments: OpenDocuments { base.openDocuments }
    var versions: PageVersionStore { base.versions }
    var versionRecorder: PageVersionRecorder { base.versionRecorder }
    var windowControl: any WindowControl { base.windowControl }
    var transferControl: (any TransferControl)? { transfer }
    var appInfo: AppInfo { base.appInfo }
    var now: Date { base.now }
    func treeDidChange(_ pageIds: Set<UUID>) { base.treeDidChange(pageIds) }
    func refreshAfterDirectWrite(pages: Set<UUID>) { base.refreshAfterDirectWrite(pages: pages) }
}

@MainActor @Suite struct TransferCommandsTests {
    /// Та же выгрузка Notion, на которой проверен импорт из меню (`NotionImporterTests`).
    static let notionExport = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("NotionImportTests/Fixtures/notion-export/synthetic", isDirectory: true)

    let host: TransferTestHost
    let executor: CommandExecutor
    let out: TemporaryFolder

    init() throws {
        host = try TransferTestHost()
        executor = CommandExecutor(host: host, log: RecordingLog())
        out = try TemporaryFolder()
    }

    private func run(_ command: String, _ args: [String: ControlJSON] = [:], cwd: String? = nil,
                     progress: @escaping (ControlProgress) -> Void = { _ in }) async -> ControlResponse {
        await executor.run(ControlRequest(command: command, args: args, cwd: cwd), progress: progress)
    }

    private var tree: PageTreeSnapshot { PageTreeSnapshot(allPages: (try? host.store.pageOutline()) ?? []) }

    /// Ветка страницы названиями: «Название» и подстраницы с отступом — для сравнения двух импортов.
    private static func outline(of rootId: UUID, in tree: PageTreeSnapshot, depth: Int = 0) -> [String] {
        tree.children(of: rootId).flatMap { [String(repeating: "  ", count: depth) + $0.title] + outline(of: $0.id, in: tree, depth: depth + 1) }
    }

    /// Все файлы папки: путь от папки → содержимое.
    private static func files(in folder: URL) throws -> [String: Data] {
        let base = folder.resolvingSymlinksInPath().path
        var result: [String: Data] = [:]
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = items?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            result[String(url.resolvingSymlinksInPath().path.dropFirst(base.count + 1))] = try Data(contentsOf: url)
        }
        return result
    }

    private func folder(_ response: ControlResponse) throws -> URL {
        URL(fileURLWithPath: try #require(response.data?["folder"]?.string), isDirectory: true)
    }

    /// Ждать условия до `seconds` секунд.
    private func eventually(seconds: Double = 30, _ condition: () throws -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try condition()
    }

    // MARK: Импорт Notion

    @Test("import notion — тот же результат и отчёт, что импорт из меню (NotionImporter.importExport)")
    func importMatchesMenuImport() async throws {
        let response = await run("import.notion", ["source": .string(Self.notionExport.path)])
        #expect(response.ok, "\(String(describing: response.error))")
        let report = try #require(response.data?["report"])

        let reference = try TestHost()
        let prepared = try NotionExportUnpacker().prepare(Self.notionExport)
        defer { prepared.discard() }
        // Как меню: с файлами вложений (картинки переносятся, а не упрощаются).
        let expected = try NotionImporter(store: reference.store, attachments: reference.attachments).importExport(prepared)

        #expect(report["pageCount"]?.int == expected.pageCount)
        #expect(report["blockCount"]?.int == expected.blockCount)
        #expect(report["rootTitle"]?.string == expected.rootTitle)
        #expect(report["notices"]?.array?.compactMap(\.string) == expected.notices)
        #expect(report["databases"]?.array?.compactMap { $0["title"]?.string } == expected.databases.map(\.title))
        #expect(report["databases"]?.array?.compactMap { $0["rowCount"]?.int } == expected.databases.map(\.rowCount))
        #expect(report["simplified"]?.array?.count == expected.simplified.count)

        let rootId = try #require(report["rootPageId"]?.string.flatMap(UUID.init(uuidString:)))
        let referenceTree = PageTreeSnapshot(allPages: try reference.store.pageOutline())
        #expect(Self.outline(of: rootId, in: tree) == Self.outline(of: expected.rootPageId, in: referenceTree))
        #expect(tree.page(rootId)?.parentId == nil)
        // Ветка появилась мимо операций дерева: окна перечитывают её, как после импорта из меню.
        #expect(host.base.directWrites.contains { $0.contains(rootId) })
        // Карточка хода в окне: начало, шаги, итог.
        #expect(host.transfer.importStarts == 1)
        #expect(!host.transfer.importSteps.isEmpty)
        #expect(host.transfer.importOutcomes == [true])
    }

    @Test("import notion --parent — ветка импорта внутри указанной страницы; путь — от папки команды")
    func importIntoParent() async throws {
        let archive = try host.base.page("Архив")
        let folder = Self.notionExport.deletingLastPathComponent()
        let response = await run("import.notion", ["source": "synthetic", "parent": "Архив"], cwd: folder.path)
        #expect(response.ok, "\(String(describing: response.error))")
        let rootId = try #require(response.data?["report"]?["rootPageId"]?.string.flatMap(UUID.init(uuidString:)))
        #expect(tree.page(rootId)?.parentId == archive.id)
        #expect(response.data?["page"]?["parentId"]?.string == archive.id.controlText)
    }

    @Test("import notion: ход строками progress — чтение, затем запись")
    func importReportsProgress() async throws {
        var steps: [ControlProgress] = []
        let response = await run("import.notion", ["source": .string(Self.notionExport.path)]) { steps.append($0) }
        #expect(response.ok)
        #expect(!steps.isEmpty)
        #expect(steps.contains { $0.stage == "reading" })
        #expect(steps.contains { $0.stage == "writing" })
        let last = try #require(steps.last { $0.stage == "writing" })
        #expect(last.done == last.total)
    }

    @Test("import notion: нет файла → file_not_found; не выгрузка Notion → invalid_value; база не тронута")
    func importErrors() async throws {
        let missing = await run("import.notion", ["source": .string(out.url.appendingPathComponent("нет.zip").path)])
        #expect(missing.error?.code == .fileNotFound)
        let empty = await run("import.notion", ["source": .string(out.url.path)])
        #expect(empty.error?.code == .invalidValue)
        #expect(try host.store.pageOutline().isEmpty)
        // Нет файла — импорт не начат; файл не из Notion — карточка в окне показывает ошибку, как у меню.
        #expect(host.transfer.importOutcomes == [false])
    }

    @Test("import notion: пока идёт импорт из меню — window_busy, второй импорт не начат")
    func importWhileMenuImportRuns() async throws {
        host.transfer.isImporting = true
        let response = await run("import.notion", ["source": .string(Self.notionExport.path)])
        #expect(response.error?.code == .windowBusy)
        #expect(try host.store.pageOutline().isEmpty)
    }

    @Test("import notion: «Остановить» в окне — ветка убрана, команда отвечает ошибкой")
    func importStoppedFromWindow() async throws {
        let big = try Self.makeLargeExport(in: out.url, pages: 400, paragraphs: 60)
        var stopped = false
        let response = await run("import.notion", ["source": .string(big.path)]) { [host] _ in
            guard !stopped else { return }
            stopped = true
            host.transfer.stopImport?()
        }
        #expect(response.error != nil)
        #expect(try host.store.pageOutline().isEmpty)
        #expect(host.transfer.importOutcomes == [false])
    }

    @Test("Чтение во время импорта не ждёт его конца")
    func readDuringImportDoesNotWait() async throws {
        let big = try Self.makeLargeExport(in: out.url, pages: 400, paragraphs: 60)
        var importDone = false
        var readFinishedBeforeImport: Bool?
        let executor = executor
        let importTask = Task { @MainActor in
            let response = await executor.run(ControlRequest(command: "import.notion", args: ["source": .string(big.path)])) { _ in }
            importDone = true
            return response
        }
        #expect(try await eventually { host.transfer.importStarts == 1 })
        let read = await run("app.status")
        readFinishedBeforeImport = !importDone
        #expect(read.ok)
        #expect(readFinishedBeforeImport == true)
        #expect(await importTask.value.ok)
    }

    @Test("Разрыв связи клиентом — импорт доходит до конца")
    func importSurvivesClientDisconnect() async throws {
        let big = try Self.makeLargeExport(in: out.url, pages: 200, paragraphs: 20)
        let stream = executor.stream(ControlRequest(command: "import.notion", args: ["source": .string(big.path)]))
        for await line in stream {
            if case .progress = line { break }
        }
        // Клиент ушёл после первой строки хода: ответ некому читать, а ветка всё равно дописывается целиком.
        #expect(try await eventually { try NotionImporter(store: host.store).runs().first?.status == .finished })
        let rootId = try #require(try NotionImporter(store: host.store).runs().first?.rootPageId)
        #expect(Self.outline(of: rootId, in: tree).count == 201)
    }

    /// Выгрузка Notion из `pages` страниц по `paragraphs` абзацев: долгий импорт без большой фикстуры в репозитории.
    static func makeLargeExport(in folder: URL, pages: Int, paragraphs: Int) throws -> URL {
        let root = folder.appendingPathComponent("Большая выгрузка", isDirectory: true)
        let top = "Корень 00000000000000000000000000000001"
        let children = root.appendingPathComponent(top, isDirectory: true)
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        try "# Корень\n\nВерх выгрузки\n".write(to: root.appendingPathComponent(top + ".md"), atomically: true, encoding: .utf8)
        let body = (1...paragraphs).map { "Абзац \($0) с обычным текстом страницы" }.joined(separator: "\n\n")
        for index in 1...pages {
            let id = String(format: "%032x", index + 1)
            try "# Страница \(index)\n\n\(body)\n".write(to: children.appendingPathComponent("Страница \(index) \(id).md"),
                                                        atomically: true, encoding: .utf8)
        }
        return root
    }

    // MARK: Выгрузка

    /// «Проекты» с двумя подстраницами (у первой — своя), «Заметки» отдельно.
    private func makeLibrary() throws -> (projects: Page, notes: Page) {
        let projects = try host.base.page("Проекты", texts: ["Все проекты", "**Важное**"])
        let first = try host.base.page("Сайт", parent: projects.id, texts: ["Макет"])
        try host.base.page("Дизайн", parent: first.id, texts: ["Цвета"])
        try host.base.page("Книга", parent: projects.id, texts: ["Глава 1"])
        let notes = try host.base.page("Заметки", texts: ["Купить молоко"])
        return (projects, notes)
    }

    private func exporter() -> MarkdownExporter {
        MarkdownExporter(store: host.store, attachmentFile: { [attachments = host.attachments] in attachments.fileURL(for: $0) })
    }

    @Test("export all — те же файлы, что выгрузка из меню")
    func exportAllMatchesMenuExport() async throws {
        try makeLibrary()
        let response = await run("export.all", ["to": .string(out.url.path)])
        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.data?["pageCount"]?.int == 5)
        let reference = try TemporaryFolder()
        let expected = try exporter().export(into: reference.url)
        #expect(try Self.files(in: try folder(response)) == Self.files(in: expected.folder))
        #expect(try folder(response).deletingLastPathComponent().resolvingSymlinksInPath() == out.url.resolvingSymlinksInPath())
    }

    @Test("export page — страница с подстраницами; --no-children — только она; файлы — как у MarkdownExporter")
    func exportPage() async throws {
        let (projects, _) = try makeLibrary()
        let withChildren = await run("export.page", ["page": "Проекты", "to": .string(out.url.path)])
        #expect(withChildren.ok, "\(String(describing: withChildren.error))")
        #expect(withChildren.data?["pageCount"]?.int == 4)
        let reference = try TemporaryFolder()
        let expected = try exporter().exportPage(projects.id, includingSubpages: true, into: reference.url)
        let files = try Self.files(in: try folder(withChildren))
        #expect(files == (try Self.files(in: expected.folder)))
        #expect(files.keys.contains("Проекты/Сайт/Дизайн.md"))
        #expect(!files.keys.contains { $0.hasPrefix("Заметки") })

        let alone = await run("export.page", ["page": "Проекты", "to": .string(out.url.path), "noChildren": true])
        #expect(alone.ok)
        #expect(alone.data?["pageCount"]?.int == 1)
        let aloneFiles = try Self.files(in: try folder(alone))
        #expect(Array(aloneFiles.keys) == ["Проекты.md"])
        let aloneExpected = try exporter().exportPage(projects.id, includingSubpages: false, into: reference.url)
        #expect(aloneFiles == (try Self.files(in: aloneExpected.folder)))
    }

    @Test("export page: ход строками progress; папки нет → file_not_found")
    func exportProgressAndMissingFolder() async throws {
        try makeLibrary()
        var steps: [ControlProgress] = []
        let response = await run("export.all", ["to": .string(out.url.path)]) { steps.append($0) }
        #expect(response.ok)
        #expect(steps.last?.done == 5 && steps.last?.total == 5)
        let missing = await run("export.page", ["page": "Проекты", "to": .string(out.url.appendingPathComponent("нет").path)])
        #expect(missing.error?.code == .fileNotFound)
    }

    @Test("export page: путь папки — от папки команды; несохранённые правки открытой страницы попадают в выгрузку")
    func exportRelativeFolderAndOpenEdits() async throws {
        let (_, notes) = try makeLibrary()
        let document = try host.openDocuments.open(notes.id)
        defer { host.openDocuments.release(notes.id) }
        document.setTitle("Заметки дома")
        try FileManager.default.createDirectory(at: out.url.appendingPathComponent("выгрузка"), withIntermediateDirectories: true)
        let response = await run("export.page", ["page": .string(notes.id.controlText), "to": "выгрузка"], cwd: out.url.path)
        #expect(response.ok, "\(String(describing: response.error))")
        #expect(try Self.files(in: try folder(response)).keys.contains("Заметки дома.md"))
    }

    @Test("db export — те же файлы, что «Выгрузить базу» из меню")
    func databaseExportMatchesMenu() async throws {
        try host.base.page("Проекты")
        let created = await run("db.create", ["parent": "Проекты", "title": "Задачи"])
        let database = try #require(created.data?["database"]?["id"]?.string.flatMap(UUID.init(uuidString:)))
        let response = await run("db.export", ["database": "Задачи", "to": .string(out.url.path)])
        #expect(response.ok, "\(String(describing: response.error))")
        let reference = try TemporaryFolder()
        let expected = try exporter().exportDatabase(database, into: reference.url)
        #expect(try Self.files(in: try folder(response)) == Self.files(in: expected.folder))
        #expect(try Self.files(in: try folder(response)).keys.contains("Задачи.csv"))
    }

    // MARK: Синхронизация

    @Test("sync status — состояние приложения; без синхронизации у хоста — выключена")
    func syncStatus() async throws {
        let synced = Date(timeIntervalSince1970: 1_800_000_000)
        host.transfer.syncState = SyncState(status: .ready, detail: "На всех ваших Mac одни и те же записи.", lastSyncedAt: synced,
                                            deviceName: "iMac")
        let response = await run("sync.status")
        #expect(response.ok)
        #expect(response.data?["enabled"]?.bool == true)
        #expect(response.data?["status"]?.string == "ready")
        #expect(response.data?["lastSyncedAt"]?.string == synced.controlText)
        #expect(response.data?["deviceName"]?.string == "iMac")

        let plain = CommandExecutor(host: try TestHost(), log: RecordingLog())
        let off = await plain.run(ControlRequest(command: "sync.status"))
        #expect(off.ok)
        #expect(off.data?["enabled"]?.bool == false)
        #expect(off.data?["status"]?.string == "off")
    }

    @Test("sync now — запускает синхронизацию приложения и отдаёт новое состояние")
    func syncNow() async throws {
        host.transfer.syncState = SyncState(status: .sending, detail: "Свежие правки уходят на другие Mac.")
        host.transfer.syncNowOutcome = .success(SyncState(status: .ready, lastSyncedAt: Date(timeIntervalSince1970: 1_800_000_100)))
        let response = await run("sync.now")
        #expect(response.ok)
        #expect(host.transfer.syncNowCalls == 1)
        #expect(response.data?["status"]?.string == "ready")
    }

    @Test("sync now при выключенной синхронизации — понятная ошибка sync_disabled, запуска нет")
    func syncNowWhenDisabled() async throws {
        let response = await run("sync.now")
        #expect(response.error?.code == .syncDisabled)
        #expect(response.error?.message.contains("выключена") == true)
        #expect(response.error?.hint?.isEmpty == false)
        #expect(host.transfer.syncNowCalls == 0)

        let plain = CommandExecutor(host: try TestHost(), log: RecordingLog())
        #expect(await plain.run(ControlRequest(command: "sync.now")).error?.code == .syncDisabled)
    }

    @Test("Импорт, выгрузка и sync now в пакет не берутся")
    func transferIsNotBatchable() async throws {
        let steps: ControlJSON = [["command": "sync.now"]]
        #expect(await run("batch", ["steps": steps]).error?.code == .notBatchable)
    }
}
