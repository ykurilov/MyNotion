import Attachments
import ControlCommands
import Foundation
import NotesCore
import PageVersions

/// Хост команд поверх библиотеки приложения: те же хранилище, документы и история, что у окон.
@MainActor
final class AppControlHost: ControlHost {
    private unowned let library: PagesLibrary
    let windowControl: any WindowControl
    let transferControl: (any TransferControl)?
    let appInfo: AppInfo

    init(library: PagesLibrary, socketPath: String, transferControl: (any TransferControl)?) {
        self.library = library
        self.transferControl = transferControl
        windowControl = AppWindowControl(library: library)
        let bundle = Bundle.main
        appInfo = AppInfo(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                          build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                          databasePath: library.store.database.url.path, socketPath: socketPath)
    }

    var store: NotesStore { library.store }
    var attachments: AttachmentStore { library.attachments }
    var openDocuments: OpenDocuments { library.openDocuments }
    var versions: PageVersionStore { library.versions.versions }
    var versionRecorder: PageVersionRecorder { library.versions.recorder }
    var now: Date { Date() }

    func treeDidChange(_ pageIds: Set<UUID>) {
        library.treeDidChange(pageIds)
    }

    /// Как после правок с другого Mac: открытые страницы принимают записанное, дерево, таблицы и окна перечитываются.
    func refreshAfterDirectWrite(pages: Set<UUID>) {
        library.openDocuments.applyExternalChanges(toPages: pages.intersection(library.openDocuments.openPageIds))
        library.remoteChangesApplied()
    }
}
