import AppKit
import Attachments
import Backlinks
import Databases
import MarkdownExport
import NotesCore
import NotionImport
import PageEditor
import PageMarkdown
import PageSearch
import ServiceLaunch
import SwiftUI
import Sync

@main
struct MyNotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let options: LaunchOptions
    private let library: Result<PagesLibrary, any Error>
    private let exportController: MarkdownExportController?
    private let importController: NotionImportController?

    init() {
        // Флаги запуска — не файлы. Иначе AppKit склеивает флаг без значения со следующим флагом в свою
        // настройку, оставшийся путь «открывает» как документ, и окно со страницей не появляется.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        // ⌘V Markdown ответа ИИ и текста со списками — блоками: разбор тот же, что у `mynotion page write`.
        PageTextView.defaultPastedTextReader = { text, html, pageId, hasRichText in
            PastedText.blocks(from: text, html: html, pageId: pageId, hasRichText: hasRichText)
        }
        let options = LaunchOptions(arguments: CommandLine.arguments)
        // До первого окна: служебный запуск не появляется в Dock и не может стать активным.
        NSApplication.shared.setActivationPolicy(options.presence.activationPolicy)
        if options.presence == .background {
            // Окна под всеми окнами — система бы усыпила приложение и растянула паузы галереи и замеров.
            AppDelegate.backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Служебный запуск MyNotion")
        }
        AppDelegate.presence = options.presence
        if let referenceLibraryURL = options.referenceLibraryURL {
            Self.generateReferenceLibraryAndExit(at: referenceLibraryURL)
        }
        self.options = options
        if let appearanceName = options.appearanceName {
            NSApplication.shared.appearance = NSAppearance(named: appearanceName)
        }
        var galleryLibrary: (GalleryLibrary, FailingWrites)?
        library = Result {
            let store = try Self.openLibrary(options)
            let reminders = ReminderNotifications(store: store, clockOffset: options.remindersClockOffset)
            reminders.installIndex()
            if options.uiGalleryURL != nil { galleryLibrary = try UIGalleryRunner.prepareLibrary(in: store) }
            // Служебные запуски (галерея, замеры, снимки) с сервером не связываются.
            let pages = PagesLibrary(store: store, startsSync: options.allowsSync, reminders: reminders, versionTiming: options.versionTiming)
            if options.uiGalleryURL != nil || options.generatesRichSample || options.generates003Sample {
                SampleMedia.materialize(in: store, attachments: pages.attachments)
            }
            if let automation = options.syncAutomation { SyncAutomation.start(automation, controller: pages.sync) }
            return pages
        }
        AppDelegate.galleryLibrary = galleryLibrary
        let pages = try? library.get()
        AppDelegate.library = pages
        if let exportURL = options.exportMarkdownURL {
            Self.exportMarkdownAndExit(from: library, into: exportURL)
        }
        if let importURL = options.importNotionURL {
            Self.importNotionAndExit(from: library, source: importURL)
        }
        exportController = pages.map { pages in
            MarkdownExportController(store: pages.store, attachments: pages.attachments, saveOpenPages: { pages.saveAll() })
        }
        importController = pages.map { pages in
            NotionImportController(store: pages.store, attachments: pages.attachments, saveOpenPages: { pages.saveAll() },
                                   showBranch: { (pages.activeWindow ?? pages.firstWindow).showImportedBranch($0) })
        }
        AppDelegate.importController = importController
        AppDelegate.exportController = exportController
        // 005: команды из командной строки — после открытия базы и отката импорта; служебные запуски сокет не занимают.
        if options.allowsSync, let pages {
            ControlBootstrap.start(library: pages, importController: importController)
        }
    }

    var body: some Scene {
        WindowGroup(id: MainWindowView.sceneId) {
            MainWindowView(library: library, options: options, exportController: exportController, importController: importController)
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowLevel(options.presence.windowLevel)
        .commands {
            PageCommands(library: try? library.get())
            SidebarToggleCommands(library: try? library.get())
            NavigationCommands(library: try? library.get())
            FormatCommands()
            PageFindCommands()
            ExportCommands(controller: exportController)
            NotionImportCommands(controller: importController)
        }
    }

    private static func openLibrary(_ options: LaunchOptions) throws -> NotesStore {
        let databaseURL = options.databaseURL ?? AppDatabase.defaultURL
        let database = try AppDatabase.open(at: databaseURL)
        // У каждой базы свой id в часах: два экземпляра с разными базами — как два Mac.
        let deviceId = options.databaseURL == nil ? DeviceIdentity.deviceId() : DeviceIdentity.deviceId(forDatabaseAt: databaseURL)
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: deviceId))
        // Индекс поиска и очередь синхронизации пишутся в той же транзакции, что и записи (research R6, R4) —
        // до первой записи. Пока синхронизация не включена, очередь ничего не пишет.
        store.addWriteHook(SearchIndexer())
        // 004: сравнимые колонки и строки поиска значений ячеек — в той же транзакции (research R3, R14).
        store.addWriteHook(CellIndexer())
        // 004, US5: зависящие формулы — в той же транзакции; полные пересчёты — в фоне (research R21).
        let formulas = FormulasAddon.install(on: store)
        // Индекс обратных ссылок — в той же транзакции, что и блок (research R10); после фиксации открытые страницы
        // перечитывают счёт, если их ссылки сменились.
        store.addWriteHook(PageLinkIndexer(onLinksChange: BacklinksAddon.linksDidChange))
        // Ссылки на файлы пересчитываются в той же транзакции, что блоки (data-model.md, «Attachment»).
        store.addWriteHook(AttachmentReferenceCounter(onQueueChange: AttachmentQueueSignal.fire))
        Outbox.install(on: store)
        // Импорт из Notion, прерванный падением приложения, не оставляет недоделанной ветки (FR-027).
        // Не вышло (диск полон) — записи всё равно открываются, журнал остаётся running и откатится в следующий раз.
        _ = try? NotionImporter(store: store).rollBackInterruptedImports()
        if options.generatesVisualSample {
            // Образец сразу открыт: для сверки с Notion и снимков окна.
            let sample = try VisualSamplePage.ensure(in: store)
            try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: sample.id))
        }
        if options.generatesRichSample {
            // Каждый тип 002 добавляет свою часть через описатель (`BlockKinds.richPageParts`).
            let pageId = try RichPageGenerator(parts: BlockKinds.richPageParts).ensure(in: store)
            try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: pageId))
        }
        if options.generates003Sample {
            // Картинки ветки — те же файлы-образцы, что у картинок «богатой» страницы (`SampleMedia`).
            let imageProps = BlockKinds.richPageParts.first { $0.name == BlockKind.image.rawValue }?.blocks.first?.props ?? .empty
            try PagesNavigationSample(imageProps: imageProps).ensure(in: store)
        }
        if options.generates004Sample {
            try DatabaseSampleGenerator().ensure(in: store)
        }
        Task { @MainActor in FormulasAddon.start(formulas) }
        if options.generates003Sample || options.generatesVersionsSample {
            // До первого окна: окно открывает страницу образца, как любую страницу базы.
            PageVersionsSampleLaunch.ensure(in: store)
        }
        if options.typingBenchmarkURL != nil {
            try TypingBenchmark.ensureHugePage(in: store)
        }
        return store
    }

    /// Служебная выгрузка без окна выбора папки: путь результата — в стандартный вывод, код выхода 0 или 1.
    private static func exportMarkdownAndExit(from library: Result<PagesLibrary, any Error>, into folder: URL) -> Never {
        do {
            let pages = try library.get()
            let attachments = pages.attachments
            let result = try MarkdownExporter(store: pages.store, attachmentFile: { attachments.fileURL(for: $0) }).export(into: folder)
            print("Выгрузка готова: \(result.folder.path) (страниц: \(result.pageCount), блоков: \(result.blockCount))")
            if result.missingFileCount > 0 { print(MarkdownExportResult.missingFilesMessage(count: result.missingFileCount)) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Выгрузка не удалась: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Служебный импорт без окна выбора: отчёт — в стандартный вывод. Код 0 — готово, 1 — ошибка (ветка откачена),
    /// 2 — эта выгрузка уже импортирована, повтор не начат.
    private static func importNotionAndExit(from library: Result<PagesLibrary, any Error>, source: URL) -> Never {
        do {
            let pages = try library.get()
            let store = pages.store
            let prepared = try NotionExportUnpacker().prepare(source)
            defer { prepared.discard() }
            let importer = NotionImporter(store: store, attachments: pages.attachments)
            if let previous = try importer.previousImport(withFingerprint: prepared.fingerprint) {
                FileHandle.standardError.write(Data("Эта выгрузка уже импортирована \(NotionImportRepeatView.dateText(previous.startedAt)) (страниц: \(previous.importedPages)), повтор не начат\n".utf8))
                exit(2)
            }
            let report = try importer.importExport(prepared)
            print("Импорт готов: ветка «\(report.rootTitle)», страниц: \(report.pageCount), блоков: \(report.blockCount)")
            for page in report.simplified { print("Упрощено: \(page.pageTitle) — \(page.items.joined(separator: ", "))") }
            for database in report.databases {
                print("База: \(database.title) — \(NotionImportReportView.rowsText(database))")
                for line in database.properties + database.notes { print("  \(line)") }
            }
            for notice in report.notices { print("Отчёт: \(notice)") }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Импорт не удался: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func generateReferenceLibraryAndExit(at url: URL) -> Never {
        do {
            try ReferenceLibraryGenerator().generate(at: url)
            print("Эталонная база создана: \(url.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Эталонная база не создана: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

/// Запись открытых страниц при уходе в фон и выходе (research R4); выход при неудачной записи — только с согласия.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Ставится при запуске, до первого окна.
    static var library: PagesLibrary?
    /// Страницы временной базы галереи (`--ui-gallery`).
    static var galleryLibrary: (GalleryLibrary, FailingWrites)?
    /// Импорт из Notion — для галереи интерфейса.
    static var importController: NotionImportController?
    /// Выгрузка в Markdown — для галереи интерфейса.
    static var exportController: MarkdownExportController?
    static var presence = LaunchPresence.foreground
    static var backgroundActivity: (any NSObjectProtocol)?

    private var sidebarShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌘⌥S — по клавише S, а не по букве: с ⌥ и на русской раскладке буква другая, и меню сочетание не узнаёт.
        // ⌥⌘N — «Новое окно» — так же.
        sidebarShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard modifiers == [.command, .option], let library = Self.library else { return event }
            switch event.keyCode {
            case Self.sKeyCode: library.activeWindow?.toggleSidebar()
            case Self.nKeyCode: library.openNewWindow?()
            default: return event
            }
            return nil
        }
    }

    /// Клавиши S и N на любой раскладке (kVK_ANSI_S, kVK_ANSI_N).
    private static let sKeyCode: UInt16 = 1
    private static let nKeyCode: UInt16 = 45

    func applicationWillResignActive(_ notification: Notification) {
        Self.library?.saveAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let library = Self.library else { return .terminateNow }
        defer { library.versions.recordAllDueBeforeQuit() }
        guard !library.saveAll() else { return .terminateNow }
        if Self.presence == .background {
            // Служебный запуск окон с вопросами не показывает: база у него своя или эталонная.
            FileHandle.standardError.write(Data("Выход без сохранения: записать правки на диск не удалось\n".utf8))
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Изменения не сохранены"
        alert.informativeText = "Записать правки на диск не удалось. Если выйти сейчас, последние правки пропадут."
        alert.addButton(withTitle: "Не выходить")
        alert.addButton(withTitle: "Выйти без сохранения")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Выход решён: сокет команд закрывается (после «Не выходить» он остаётся).
    func applicationWillTerminate(_ notification: Notification) {
        ControlBootstrap.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// «Файл»: новая страница, подстраница и окно; «Правка → Найти страницу». Действуют в окне, где работают.
private struct PageCommands: Commands {
    let library: PagesLibrary?
    @FocusedValue(\.windowModel) private var focusedModel
    @Environment(\.openWindow) private var openWindow

    private var model: MainWindowModel? { focusedModel ?? library?.activeWindow }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новая страница") { model?.createPage() }
                .keyboardShortcut("n")
            Button("Новая подстраница") { model?.createSubpage() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            // ⌘D и ⇧⌘P в тексте страницы берёт редактор (блоки); здесь — фокус в панели, в названии или «Недавние» нет.
            Button("Дублировать страницу") { model?.openPageId.map { model?.duplicatePage($0) } }
                .keyboardShortcut("d")
                .disabled(model?.openPageId == nil)
            Button("Переместить страницу в…") { model?.openPageId.map { model?.showMovePagePicker($0) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model?.openPageId == nil)
            // Сочетание ловит и `AppDelegate`: с ⌥ буква на русской раскладке другая.
            Button("Новое окно") { openWindow(id: MainWindowView.sceneId) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(library == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Найти страницу") { model?.search.focusField() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        // Настройки — карточкой поверх окна (contracts/visual-style.md, «Окна поверх страницы»), а не отдельным окном.
        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") { model?.isSyncSettingsShown = true }
                .keyboardShortcut(",")
                .disabled(model == nil)
        }
    }
}

/// «Вид → Скрыть/Показать боковую панель», ⌘⌥S (contracts/editor-interactions.md).
private struct SidebarToggleCommands: Commands {
    let library: PagesLibrary?
    @FocusedValue(\.windowModel) private var focusedModel

    private var model: MainWindowModel? { focusedModel ?? library?.activeWindow }

    var body: some Commands {
        CommandGroup(before: .sidebar) {
            Button(model?.isSidebarCollapsed == true ? "Показать боковую панель" : "Скрыть боковую панель") {
                model?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(model == nil)
        }
    }
}
