import Foundation
import NotesCore
import PageVersions

/// `--generate-003-sample`: история версий — страница «Замер: история версий» и 200 версий у «богатой» страницы,
/// если она есть (quickstart.md, «Эталон»).
enum PageVersionsSampleLaunch {
    static func ensure(in store: NotesStore) {
        let versions = PageVersionStore(store: store)
        let deviceName = Host.current().localizedName ?? "Mac"
        _ = try? PageVersionsSample.ensure(in: store, versions: versions, deviceName: deviceName)
        if let rich = try? store.pageOutline().first(where: { $0.title == RichPageGenerator.title && $0.trashedAt == nil }) {
            try? PageVersionsSample.addHistory(toPage: rich.id, in: store, versions: versions, deviceName: deviceName)
        }
    }
}
