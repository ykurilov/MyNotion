import NotesCore
import SwiftUI

/// MyNotion для iPhone, этап 0: открывает базу записей в папке приложения и показывает число страниц —
/// так видно, что общее ядро живёт на iOS (specs/007-iphone-app/plan-draft.md).
@main
struct MyNotionPhoneApp: App {
    private let library = Result { try LibraryCheck.open() }

    var body: some Scene {
        WindowGroup {
            LibraryStatusView(library: library)
        }
    }
}

/// Что удалось открыть: путь к базе и число страниц в ней.
struct LibraryCheck {
    let databaseURL: URL
    let pageCount: Int

    static func open() throws -> LibraryCheck {
        let database = try AppDatabase.open(at: AppDatabase.defaultURL)
        let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: DeviceIdentity.deviceId()))
        return LibraryCheck(databaseURL: database.url, pageCount: try store.pageOutline().count)
    }
}

struct LibraryStatusView: View {
    let library: Result<LibraryCheck, any Error>

    var body: some View {
        VStack(spacing: 12) {
            Text("MyNotion")
                .font(.largeTitle.bold())
            switch library {
            case .success(let check):
                Text("Страниц в базе: \(check.pageCount)")
                    .font(.title3)
                Text(check.databaseURL.lastPathComponent)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .failure(let error):
                Text("База не открылась: \(error.localizedDescription)")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}
