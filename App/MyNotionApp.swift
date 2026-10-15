import AppKit
import NotesCore
import ServiceLaunch
import SwiftUI

@main
struct MyNotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let options: LaunchOptions
    private let library: Result<MainWindowModel, any Error>

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
            return MainWindowModel(store: store)
        }
        AppDelegate.galleryLibrary = galleryLibrary
        AppDelegate.model = try? library.get()
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView(library: library, options: options)
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
            FormatCommands()
        }
    }

    private static func openLibrary(_ options: LaunchOptions) throws -> NotesStore {
        let database = try AppDatabase.open(at: options.databaseURL ?? AppDatabase.defaultURL)
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: DeviceIdentity.deviceId()))
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
