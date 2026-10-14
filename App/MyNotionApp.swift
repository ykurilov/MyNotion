import NotesCore
import SwiftUI

@main
struct MyNotionApp: App {
    private let options: LaunchOptions
    private let library: Result<NotesStore, any Error>

    init() {
        let options = LaunchOptions(arguments: CommandLine.arguments)
        if let referenceLibraryURL = options.referenceLibraryURL {
            Self.generateReferenceLibraryAndExit(at: referenceLibraryURL)
        }
        self.options = options
        library = Result { try Self.openLibrary(options) }
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView(library: library, launchReportURL: options.launchReportURL)
        }
    }

    private static func openLibrary(_ options: LaunchOptions) throws -> NotesStore {
        let database = try AppDatabase.open(at: options.databaseURL ?? AppDatabase.defaultURL)
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: DeviceIdentity.deviceId()))
        if options.generatesVisualSample {
            try VisualSamplePage.ensure(in: store)
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
