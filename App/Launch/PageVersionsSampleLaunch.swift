import Foundation
import NotesCore
import PageVersions

/// `--generate-003-sample`: история версий — страница «Замер: история версий» и 200 версий у «богатой» страницы,
/// если она есть (quickstart.md, «Эталон»).
@MainActor
enum PageVersionsSampleLaunch {
    static func ensure(in library: PagesLibrary) {
        let versions = library.versions.versions
        let deviceName = library.sync.deviceName
        _ = try? PageVersionsSample.ensure(in: library.store, versions: versions, deviceName: deviceName)
        if let rich = try? library.store.pageOutline().first(where: { $0.title == RichPageGenerator.title && $0.trashedAt == nil }) {
            try? PageVersionsSample.addHistory(toPage: rich.id, in: library.store, versions: versions, deviceName: deviceName)
        }
        library.reloadTree()
    }
}
