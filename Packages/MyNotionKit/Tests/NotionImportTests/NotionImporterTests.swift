import Foundation
import GRDB
import NotesCore
import Synchronization
import Testing
@testable import NotionImport

/// Импорт выгрузки Notion в ветку дерева (T085, FR-025…FR-027, contracts/files-import-export.md).
@Suite("Импорт из Notion")
struct NotionImporterTests {
    private let workFolder: URL
    private let store: NotesStore
    private let importDate = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 15))!

    /// Образцы — ресурсы модуля тестов: находятся и там, где исходников нет (виртуальный Mac).
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/notion-export", isDirectory: true)
    static let synthetic = fixtures.appendingPathComponent("synthetic", isDirectory: true)
    static let syntheticZip = fixtures.appendingPathComponent("synthetic-nested.zip")
    static let liveZip = fixtures.appendingPathComponent("live-mynotion-comparison.zip")
    /// Выгрузка Notion 7.39 «MyNotion — сравнение» с подстраницей «MyNotion — блоки 002» (T116, 19.10.2026).
    static let live002Zip = fixtures.appendingPathComponent("live-mynotion-002-blocks.zip")

    init() throws {
        workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        store = NotesStore(database: try AppDatabase.open(at: workFolder.appendingPathComponent("MyNotion.sqlite")),
                           clock: HybridLogicalClock(deviceId: UUID()))
    }

    private func importer() -> NotionImporter {
        NotionImporter(store: store, now: { [importDate] in importDate })
    }

    @discardableResult
    private func runImport(_ source: URL = synthetic, importer: NotionImporter? = nil) throws -> NotionImportReport {
        let prepared = try NotionExportUnpacker().prepare(source)
        defer { prepared.discard() }
        return try (importer ?? self.importer()).importExport(prepared)
    }

    private var tree: PageTreeSnapshot { PageTreeSnapshot(allPages: (try? store.pageOutline()) ?? []) }

    private func child(_ title: String, of parentId: UUID?) throws -> Page {
        try #require(tree.children(of: parentId).first { $0.title == title }, "Нет страницы «\(title)»")
    }

    /// Блоки потока страницы по порядку; ячейки таблиц и блоки колонок — в своих потоках.
    private func blocks(of page: Page) throws -> [Block] {
        try #require(try store.pageContent(page.id)).blocks.filter { $0.containerId == nil }
    }

    private func texts(of page: Page) throws -> [String] {
        try blocks(of: page).map(\.text.string)
    }

    // MARK: Ветка и вложенность

    @Test("Всё попадает в новую ветку «Импорт из Notion — <дата>» в конце корня; прежние страницы не тронуты")
    func importBranch() throws {
        let existing = try store.write { try $0.createPage(title: "Мои записи") }
        let report = try runImport()

        let roots = tree.children(of: nil)
        #expect(roots.map(\.title) == ["Мои записи", "Импорт из Notion — 18 октября 2026"])
        #expect(report.rootPageId == roots[1].id)
        #expect(report.rootTitle == "Импорт из Notion — 18 октября 2026")
        #expect(try store.pageContent(existing.id)?.blocks.map(\.kind) == [.paragraph])
        // Ветка ссылается на свои верхние страницы, как обычная страница на подстраницы.
        let topPages = tree.children(of: report.rootPageId)
        #expect(topPages.map(\.title) == ["Дневник", "Проекты"])
        #expect(try blocks(of: roots[1]).map(\.linkedPageId) == topPages.map(\.id))
    }

    @Test("Вложенность — из путей: хвосты <32 hex> отрезаются, папка рядом с файлом — подстраницы")
    func nestingFromPaths() throws {
        let report = try runImport()
        let projects = try child("Проекты", of: report.rootPageId)
        #expect(projects.icon == "📁")
        #expect(tree.children(of: projects.id).map(\.title) == ["MyNotion", "Задачи"])
        let mynotion = try child("MyNotion", of: projects.id)
        let ideas = try child("Идеи", of: mynotion.id)
        #expect(ideas.icon == "💡")
        let tasks = try child("Задачи", of: projects.id)
        // Таблица — база (004): строки — её страницы; строке без файла — новая страница.
        #expect(try store.pageOutline().filter { $0.parentId == tasks.id }.map(\.title).sorted() == ["Купить молоко", "Починить кран"])
        #expect(report.pageCount == 7)
    }

    @Test("Порядок подстраниц — как ссылки на них в родителе, а ссылки становятся блоками pageLink")
    func subpageLinks() throws {
        let report = try runImport()
        let projects = try child("Проекты", of: report.rootPageId)
        let links = try blocks(of: projects).filter { $0.kind == .pageLink }
        let mynotion = try child("MyNotion", of: projects.id)
        let tasks = try child("Задачи", of: projects.id)
        let diary = try child("Дневник", of: report.rootPageId)
        // MyNotion — подстраница, Дневник — ссылка на страницу из другой ветки; Задачи — встроенная база на месте ссылки.
        #expect(links.map(\.linkedPageId) == [mynotion.id, diary.id])
        #expect(try blocks(of: projects).first { $0.kind == .database }?.linkedPageId == tasks.id)
    }

    @Test("Ссылка на страницу, которой нет в выгрузке, — простой текст с названием")
    func missingPageLinkBecomesText() throws {
        let report = try runImport()
        let projects = try child("Проекты", of: report.rootPageId)
        #expect(try texts(of: projects).contains("Удалённая страница"))
    }

    @Test("Ссылка на страницу выгрузки в строке текста — упоминание её (002); ссылка notion.so остаётся ссылкой")
    func notionURLLinks() throws {
        let report = try runImport()
        let projects = try child("Проекты", of: report.rootPageId)
        let diary = try #require(tree.pagesInTreeOrder.first { $0.title == "Дневник" })
        let mixed = try #require(try blocks(of: projects).first { $0.text.string.hasPrefix("Ссылка на ") })
        #expect(mixed.text.string == "Ссылка на \u{FFFC} внутри текста и на MyNotion.")
        #expect(mixed.text.runs.map(\.style) == [.mention(diary.id),
                                                 .link(URL(string: "https://www.notion.so/MyNotion-2a3b4c5d6e7f8091a2b3c4d5e6f70812?pvs=21")!)])
    }

    // MARK: Содержимое

    @Test("Поддерживаемые блоки переносятся как есть")
    func supportedBlocks() throws {
        let report = try runImport()
        let projects = try blocks(of: child("Проекты", of: report.rootPageId))
        #expect(projects.prefix(13).map(\.kind) == [.paragraph, .heading2, .heading3, .bulletItem, .bulletItem, .bulletItem,
                                                    .numberedItem, .numberedItem, .numberedItem, .checkbox, .checkbox,
                                                    .pageLink, .database])
        #expect(projects.prefix(11).map(\.indent) == [0, 0, 0, 0, 1, 2, 0, 0, 1, 0, 0])
        #expect(projects[10].isChecked)
        #expect(projects[0].text.string.hasSuffix("подчёркнутый и ссылка.\nВторая строка того же абзаца."))
        #expect(Set(projects[0].text.runs.map(\.style)) == [.bold, .italic, .strikethrough, .code, .underline,
                                                            .link(URL(string: "https://example.com/путь?a=1")!)])
    }

    @Test("CSV-таблица — база (004): берётся полная _all.csv, строки — страницы, строки свойств отрезаны от тела")
    func csvTable() throws {
        let report = try runImport()
        let tasks = try #require(try store.pageOutline().first { $0.title == "Задачи" })
        #expect(try store.write { tx throws in try tx.database(tasks.id) } != nil)
        #expect(try store.write { tx throws in try tx.properties(ofDatabase: tasks.id) }.map(\.name) == ["Название", "Статус", "Заметки", "Срок"])
        let rows = try store.pageOutline().filter { $0.parentId == tasks.id }.sorted { $0.sortKey < $1.sortKey }
        #expect(rows.map(\.title) == ["Купить молоко", "Починить кран"])
        #expect(try texts(of: rows[0]) == ["Две бутылки."])
        #expect(report.databases.map(\.title) == ["Задачи"])
    }

    @Test("Картинки и вложения — «[файл: имя]», сами файлы не копируются")
    func files() throws {
        let report = try runImport()
        let projects = try child("Проекты", of: report.rootPageId)
        let ideas = try child("Идеи", of: child("MyNotion", of: projects.id).id)
        #expect(try texts(of: ideas).contains("[файл: schema.png]"))
        #expect(try texts(of: projects).contains("[файл: отчёт.pdf]"))
    }

    @Test("Встраивания — абзацы с исходным текстом; цитата, выноска, переключатель (US1), код и формула (US4), таблица (US6) — блоками")
    @MainActor
    func unsupportedBecomeParagraphs() throws {
        let report = try runImport()
        let projects = try blocks(of: child("Проекты", of: report.rootPageId))
        let paragraphs = projects.filter { $0.kind == .paragraph }.map(\.text.string)
        for expected in ["Текст внутри", "https://www.youtube.com/embed/xyz"] {
            #expect(paragraphs.contains(expected), "Нет абзаца «\(expected)»")
        }
        #expect(projects.contains { $0.kind == .code && $0.text.string == "let answer = 42\nprint(answer)" })
        #expect(projects.contains { $0.kind == .equation && $0.text.string == "E = mc^2" })
        let content = try #require(try store.pageContent(child("Проекты", of: report.rootPageId).id))
        let document = PageDocument(content: content)
        let table = try #require(document.blocks.first { $0.kind == .table })
        let grid = try #require(document.tableGrid(table.id))
        #expect((0..<grid.rowCount).map { row in (0..<grid.columnCount).map { grid.text(row: row, column: $0).string } }
                == [["Имя", "Роль"], ["Юрий", "автор"], ["Мишка", "тестировщик"]])
        #expect(projects.contains { $0.kind == .quote && $0.text.string == "Цитата из книги" })
        let callout = try #require(projects.first { $0.kind == .callout })
        #expect(callout.text.string == "Выноска с советом")
        #expect(callout.props.icon == "💡")
        #expect(callout.color.background == .gray)
        let toggle = try #require(projects.firstIndex { $0.kind == .toggle && $0.text.string == "Ещё переключатель" })
        #expect(projects[toggle + 1].text.string == "Текст внутри" && projects[toggle + 1].indent == 1)
        #expect(projects.contains { $0.kind == .divider })
    }

    // MARK: Отчёт и журнал

    @Test("Отчёт: число страниц и блоков, «страница — что упрощено»; журнал импорта — finished")
    func report() throws {
        let report = try runImport()
        #expect(report.pageCount == 7)
        // Страница-база своих блоков не пишет (пустой абзац у неё — правило ядра); строки базы в дереве не видны.
        let databases = Set(try store.write { tx throws in try tx.allDatabaseRecords() }.databases.map(\.pageId))
        let stored = try store.pageOutline().filter {
            ($0.parentId.map(databases.contains) == true || tree.isPage($0.id, insideBranchOf: report.rootPageId))
                && $0.id != report.rootPageId && !databases.contains($0.id)
        }
        let blockCount = try stored.reduce(0) { $0 + (try store.pageContent($1.id)?.blocks.count ?? 0) }
        #expect(report.blockCount == blockCount)
        let projects = try #require(report.simplified.first { $0.pageTitle == "Проекты" })
        // Цитаты, выноски, переключатели и разделители (US1), код и формулы (US4), таблицы (US6) переносятся блоками
        // и в отчёт не попадают.
        #expect(projects.items == [
            "картинки и файлы — вместо них их имена", "встроенные видео и сайты — вместо них их адреса",
        ])
        // Таблица — база (004), а не упрощение.
        #expect(report.simplified.map(\.pageTitle).sorted() == ["Идеи", "Проекты"])
        #expect(NotionSimplification.quote.title(count: 12) == "цитаты (12)")
        // Чего в Markdown Notion нет, отчёт называет всегда, даже если упрощать было нечего (research R14).
        #expect(report.notices == ["Цвета и колонки Notion в Markdown не выгружает — они не перенесены", "Обложки страниц Notion в выгрузку не попадают"]
                + NotionDatabaseReader.notionNotices)

        let run = try #require(try importer().runs().first)
        #expect(run.status == .finished)
        #expect(run.rootPageId == report.rootPageId)
        #expect(run.importedPages == 7)
        #expect(run.simplifiedItems == report.simplified)
        #expect(run.startedAt == importDate)
        #expect(run.finishedAt != nil)
    }

    // MARK: Распаковка и отпечаток

    @Test("ZIP со вложенными ZIP распаковывается во временную папку и даёт тот же отпечаток, что папка")
    func nestedZip() throws {
        let fromZip = try NotionExportUnpacker().prepare(Self.syntheticZip)
        let fromFolder = try NotionExportUnpacker().prepare(Self.synthetic)
        defer { fromZip.discard(); fromFolder.discard() }
        #expect(fromZip.fingerprint == fromFolder.fingerprint)
        #expect(fromFolder.contentRoot.standardizedFileURL == Self.synthetic.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: fromZip.contentRoot.appendingPathComponent("ExportBlock-0b6f2c1e-4d7a-4f3e-9a51-6c2d8e9f0a13-Part-1.zip").path))

        let report = try importer().importExport(fromZip)
        #expect(report.pageCount == 7)
        let folder = fromZip.contentRoot
        fromZip.discard()
        #expect(!FileManager.default.fileExists(atPath: folder.path), "Временная папка распаковки не убрана")
    }

    @Test("Не выгрузка Notion — понятная ошибка, база не тронута")
    func notAnExport() throws {
        let empty = workFolder.appendingPathComponent("Пусто", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try Data("просто текст".utf8).write(to: empty.appendingPathComponent("заметка.txt"))
        #expect(throws: NotionImportError.notAnExport) { try runImport(empty) }
        let broken = workFolder.appendingPathComponent("сломанный.zip")
        try Data("не zip".utf8).write(to: broken)
        #expect { try NotionExportUnpacker().prepare(broken) } throws: { error in
            if case NotionImportError.cannotUnpack = error { true } else { false }
        }
        #expect(try store.pageOutline().isEmpty)
    }

    // MARK: Повтор и сбои (FR-027)

    @Test("Повтор той же выгрузки находится по отпечатку до начала импорта")
    func repeatedImportIsDetected() throws {
        let prepared = try NotionExportUnpacker().prepare(Self.synthetic)
        defer { prepared.discard() }
        #expect(try importer().previousImport(withFingerprint: prepared.fingerprint) == nil)
        let report = try importer().importExport(prepared)
        let previous = try #require(try importer().previousImport(withFingerprint: prepared.fingerprint))
        #expect(previous.rootPageId == report.rootPageId)
        #expect(previous.status == .finished)
        // Та же выгрузка в ZIP — та же.
        let zipped = try NotionExportUnpacker().prepare(Self.syntheticZip)
        defer { zipped.discard() }
        #expect(try importer().previousImport(withFingerprint: zipped.fingerprint)?.id == previous.id)
    }

    @Test("Сбой записи посреди импорта откатывает ветку целиком; журнал — failed; прежние записи целы")
    func failedImportRollsBack() throws {
        let existing = try store.write { try $0.createPage(title: "Мои записи") }
        let hook = FailingHook(failAfter: 3)
        store.addWriteHook(hook)
        var pageByPage = importer()
        pageByPage.maxBlocksPerTransaction = 1
        #expect(throws: NotionImportError.self) { try runImport(importer: pageByPage) }
        hook.disarm()

        #expect(try store.pageOutline().map(\.id) == [existing.id])
        let run = try #require(try importer().runs().first)
        #expect(run.status == .failed)
        #expect(try importer().previousImport(withFingerprint: run.sourceFingerprint) == nil, "Неудачный импорт не считается повтором")
    }

    @Test("Отмена посреди записи откатывает ветку")
    func cancelledImportRollsBack() async throws {
        let prepared = try NotionExportUnpacker().prepare(Self.synthetic)
        defer { prepared.discard() }
        var pageByPage = importer()
        pageByPage.maxBlocksPerTransaction = 1
        let importer = pageByPage
        let task = Task.detached {
            try importer.importExport(prepared) { step in
                // Две страницы уже записаны — Юрий нажимает «Остановить».
                if step.phase == .writing, step.done == 2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try store.pageOutline().isEmpty)
        #expect(try importer.runs().first?.status == .failed)
    }

    @Test("Импорт, прерванный падением приложения, откатывается при следующем запуске")
    func interruptedImportIsRolledBackOnLaunch() throws {
        let existing = try store.write { try $0.createPage(title: "Мои записи") }
        var crashing = importer()
        crashing.rollsBackOnFailure = false
        crashing.maxBlocksPerTransaction = 1
        let hook = FailingHook(failAfter: 3)
        store.addWriteHook(hook)
        #expect(throws: NotionImportError.self) { try runImport(importer: crashing) }
        hook.disarm()
        #expect(try store.pageOutline().count > 3, "Падение должно оставить недоделанную ветку")
        #expect(try importer().runs().first?.status == .running)

        #expect(try importer().rollBackInterruptedImports() == 1)
        #expect(try store.pageOutline().map(\.id) == [existing.id])
        #expect(try importer().runs().first?.status == .failed)
        #expect(try importer().rollBackInterruptedImports() == 0)
    }

    @Test("Ход работы: чтение, затем запись, до конца")
    func progress() throws {
        let steps = Mutex<[NotionImportProgress]>([])
        let prepared = try NotionExportUnpacker().prepare(Self.synthetic)
        defer { prepared.discard() }
        _ = try importer().importExport(prepared) { step in steps.withLock { $0.append(step) } }
        let all = steps.withLock { $0 }
        #expect(all.first?.phase == .reading)
        // Строке таблицы без своего файла — новая страница: записано на одну больше, чем прочитано.
        #expect(all.last == NotionImportProgress(phase: .writing, done: 7, total: 7))
        #expect(all.contains { $0.phase == .reading && $0.done == $0.total && $0.total == 6 })
    }

    // MARK: Живая выгрузка Notion 7.38.1

    @Test("Живая выгрузка «MyNotion — сравнение»: обёртка «Private & Shared», папки подстраниц без хвоста hex")
    func liveExport() throws {
        let report = try runImport(Self.liveZip)
        #expect(report.pageCount == 3)
        let page = try child("MyNotion — сравнение", of: report.rootPageId)
        let subpages = tree.children(of: page.id)
        #expect(subpages.map(\.title) == ["Подстраница первая", "Подстраница без иконки"])
        let content = try blocks(of: page)
        #expect(content.suffix(2).map(\.linkedPageId) == subpages.map(\.id))
        #expect(content.contains { $0.kind == .checkbox && $0.indent == 1 && $0.text.string == "Вложенная задача" })
        #expect(content.contains { $0.text.string == "Первая строка блока\nВторая строка после переноса\nТретья строка после переноса" })
        #expect(report.simplified.isEmpty)
        #expect(report.notices == [NotionImportReport.markdownLossNotice, NotionImportReport.coverLossNotice])
    }

    @Test("Живая выгрузка Notion 7.39 с блоками 002: всё, что Notion пишет в Markdown, — нужными блоками (T116)")
    func live002Export() throws {
        let report = try runImport(Self.live002Zip)
        #expect(report.pageCount == 4)
        let comparison = try child("MyNotion — сравнение", of: report.rootPageId)
        #expect(tree.children(of: comparison.id).map(\.title) == ["Подстраница первая", "Подстраница без иконки", "MyNotion — блоки 002"])
        let page = try child("MyNotion — блоки 002", of: comparison.id)
        let shape = try blocks(of: page).map { "\($0.indent) \($0.kind.rawValue) \($0.text.string)" }
        #expect(shape == [
            // Переключатель Notion пишет пунктом списка с текстом внутри — от пункта его не отличить.
            "0 bulletItem Переключатель", "1 paragraph Внутри переключателя",
            "0 quote Цитата из книги", "0 paragraph Абзац после разделителя", "0 divider ", "0 callout Совет в выноске",
            "0 code let x = 1", "0 equation E = mc^2",
            // Дату Notion пишет простым текстом, без «@».
            "0 paragraph Формула в строке \u{FFFC} и дата October 20, 2026",
            // Цвет Notion не выгружает.
            "0 paragraph Красный абзац",
            "0 table ", "0 bookmark ",
            // Колонки Notion пишет подряд.
            "0 paragraph Левая колонка", "0 paragraph Правая колонка",
            "0 video ",
        ])
        let content = try blocks(of: page)
        #expect(content.first { $0.kind == .callout }?.props.icon == "💡")
        #expect(content.first { $0.kind == .code }?.props.language == "jsx")
        #expect(content.first { $0.text.string.hasPrefix("Формула") }?.text.runs.map(\.style) == [.equation("a^2+b^2")])
        #expect(content.first { $0.kind == .bookmark }?.props.title == "Help, Support, and Documentation for Notion")
        #expect(content.first { $0.kind == .video }?.props.videoSource == .youtube)
        #expect(report.simplified.isEmpty)
        #expect(report.notices == [NotionImportReport.markdownLossNotice, NotionImportReport.coverLossNotice])
    }
}

/// Подписчик на запись, который роняет одну транзакцию после нескольких удачных: как сбой диска.
final class FailingHook: NotesWriteHook, Sendable {
    private let remaining: Mutex<Int?>
    init(failAfter: Int) { remaining = Mutex(failAfter) }

    func disarm() { remaining.withLock { $0 = nil } }

    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        try remaining.withLock { remaining in
            guard let count = remaining else { return }
            if count == 0 {
                remaining = nil
                throw DiskFull()
            }
            remaining = count - 1
        }
    }

    struct DiskFull: Error, LocalizedError {
        var errorDescription: String? { "на диске нет места" }
    }
}
