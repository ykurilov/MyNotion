import AppKit
import MarkdownExport
import NotesCore
import PageSearch
import ServiceLaunch
import SwiftUI
import Sync

@main
struct MyNotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let options: LaunchOptions
    private let library: Result<MainWindowModel, any Error>
    private let exportController: MarkdownExportController?

    init() {
        // Флаги запуска — не файлы. Иначе AppKit склеивает флаг без значения со следующим флагом в свою
        // настройку, оставшийся путь «открывает» как документ, и окно со страницей не появляется.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
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
            if options.uiGalleryURL != nil { galleryLibrary = try UIGalleryRunner.prepareLibrary(in: store) }
            // Служебные запуски (галерея, замеры, снимки) с сервером не связываются.
            let model = MainWindowModel(store: store, startsSync: options.allowsSync)
            if let automation = options.syncAutomation { SyncAutomation.start(automation, controller: model.sync) }
            return model
        }
        AppDelegate.galleryLibrary = galleryLibrary
        let model = try? library.get()
        AppDelegate.model = model
        if let exportURL = options.exportMarkdownURL {
            Self.exportMarkdownAndExit(from: library, into: exportURL)
        }
        exportController = model.map { model in
            MarkdownExportController(store: model.store, saveOpenPages: { model.saveAll() })
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView(library: library, options: options, exportController: exportController)
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowLevel(options.presence.windowLevel)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Новая страница") { (try? library.get())?.createPage() }
                    .keyboardShortcut("n")
                Button("Новая подстраница") { (try? library.get())?.createSubpage() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Найти страницу") { (try? library.get())?.search.focusField() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            SidebarToggleCommands(model: try? library.get())
            FormatCommands()
            ExportCommands(controller: exportController)
        }
        Settings {
            if let model = try? library.get() {
                SyncSettingsView(controller: model.sync)
            }
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
        Outbox.install(on: store)
        if options.generatesVisualSample {
            // Образец сразу открыт: для сверки с Notion и снимков окна.
            let sample = try VisualSamplePage.ensure(in: store)
            try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: sample.id))
        }
        if options.typingBenchmarkURL != nil {
            try TypingBenchmark.ensureHugePage(in: store)
        }
        return store
    }

    /// Служебная выгрузка без окна выбора папки: путь результата — в стандартный вывод, код выхода 0 или 1.
    private static func exportMarkdownAndExit(from library: Result<MainWindowModel, any Error>, into folder: URL) -> Never {
        do {
            let result = try MarkdownExporter(store: library.get().store).export(into: folder)
            print("Выгрузка готова: \(result.folder.path) (страниц: \(result.pageCount), блоков: \(result.blockCount))")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Выгрузка не удалась: \(error.localizedDescription)\n".utf8))
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
    static var model: MainWindowModel?
    /// Страницы временной базы галереи (`--ui-gallery`).
    static var galleryLibrary: (GalleryLibrary, FailingWrites)?
    static var presence = LaunchPresence.foreground
    static var backgroundActivity: (any NSObjectProtocol)?

    private var sidebarShortcutMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ⌘⌥S — по клавише S, а не по букве: с ⌥ и на русской раскладке буква другая, и меню сочетание не узнаёт.
        sidebarShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard event.keyCode == Self.sKeyCode, modifiers == [.command, .option], let model = Self.model else { return event }
            model.toggleSidebar()
            return nil
        }
    }

    /// Клавиша S на любой раскладке (kVK_ANSI_S).
    private static let sKeyCode: UInt16 = 1

    func applicationWillResignActive(_ notification: Notification) {
        Self.model?.saveAll()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, !model.saveAll() else { return .terminateNow }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// «Вид → Скрыть/Показать боковую панель», ⌘⌥S (contracts/editor-interactions.md).
private struct SidebarToggleCommands: Commands {
    let model: MainWindowModel?

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
