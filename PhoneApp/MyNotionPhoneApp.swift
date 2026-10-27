import PhoneShell
import SwiftUI

/// MyNotion для iPhone: дерево страниц, страница и синхронизация с Mac (specs/007-iphone-app).
@main
struct MyNotionPhoneApp: App {
    private let options: PhoneLaunchOptions
    private let library: Result<PhoneLibrary, any Error>

    init() {
        #if DEBUG
        let options = PhoneLaunchOptions.parse(CommandLine.arguments)
        #else
        // Сборка для TestFlight флагов снимков и живой проверки не принимает: ни чужой базы, ни кода из файла.
        let options = PhoneLaunchOptions()
        #endif
        self.options = options
        library = Result { try PhoneLibrary(options: options) }
    }

    var body: some Scene {
        WindowGroup {
            switch library {
            case .success(let library): PhoneRootView(library: library, options: options)
            case .failure(let error): LibraryFailureView(error: error)
            }
        }
    }
}

/// Навигация приложения: дерево → страницы (назад кнопкой и жестом), листы подключения и настроек.
/// Уход в фон и возвращение передаются синхронизации.
struct PhoneRootView: View {
    let library: PhoneLibrary
    let options: PhoneLaunchOptions
    @State private var path: [UUID] = []
    @State private var sheet: Sheet?
    @Environment(\.scenePhase) private var scenePhase

    enum Sheet: Identifiable {
        case connect, settings
        var id: Self { self }
    }

    var body: some View {
        NavigationStack(path: $path) {
            PageTreeScreen(library: library, openPage: open, showConnect: { sheet = .connect },
                           showSettings: { sheet = .settings })
                .navigationDestination(for: UUID.self) { pageId in
                    PageContainer(pageId: pageId, library: library, openPage: open)
                }
        }
        .tint(PhoneTheme.textPrimary)
        .sheet(item: $sheet) { sheet in
            NavigationStack {
                switch sheet {
                case .connect:
                    ConnectScreen(sync: library.sync, close: { self.sheet = nil })
                case .settings:
                    SyncSettingsScreen(sync: library.sync, connect: { self.sheet = .connect }, close: { self.sheet = nil })
                }
            }
            .tint(PhoneTheme.accent)
        }
        .onChange(of: library.browser.revision) {
            // Страницу удалили на другом устройстве — уйти с неё.
            path.removeAll { !library.browser.isAvailable($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: library.sync.didEnterBackground()
            case .active: library.sync.willEnterForeground()
            default: break
            }
        }
        .task { openInitialScreen() }
        .task { await LiveCheck.run(options: options, library: library) }
    }

    private func open(_ pageId: UUID) {
        path.append(pageId)
    }

    private func openInitialScreen() {
        switch options.initialScreen {
        case .connect: sheet = .connect
        case .settings: sheet = .settings
        case .page(let title):
            let page = (try? library.store.pageOutline())?.first { $0.title == title && library.browser.isAvailable($0.id) }
            if let page { path = library.browser.ancestors(of: page.id).map(\.id) + [page.id] }
        case nil: break
        }
    }
}

private struct LibraryFailureView: View {
    let error: any Error

    var body: some View {
        ContentUnavailableView("База записей не открылась", systemImage: "exclamationmark.triangle",
                               description: Text(error.localizedDescription))
    }
}
