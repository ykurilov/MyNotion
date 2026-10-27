import Foundation
import NotesCore
import PhoneShell
import Sync
import UIKit

/// Всё, что живёт столько же, сколько приложение: база, открытые страницы, дерево и синхронизация.
/// Пришедшие с других устройств правки сами перечитывают дерево; открытые страницы получают их через `OpenDocuments`.
@MainActor
final class PhoneLibrary {
    let store: NotesStore
    let openDocuments: OpenDocuments
    let browser: PageBrowser
    let sync: PhoneSyncController

    init(options: PhoneLaunchOptions) throws {
        let database = try AppDatabase.open(at: options.databaseURL ?? AppDatabase.defaultURL)
        store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: DeviceIdentity.deviceId()))
        openDocuments = OpenDocuments(store: store)
        sync = PhoneSyncController(store: store, openDocuments: openDocuments,
                                   deviceName: options.syncDeviceName ?? UIDevice.current.name, secrets: SyncKeychain(),
                                   backgroundTime: UIKitBackgroundTime())
        if let server = options.syncServer, !sync.isEnabled { sync.serverAddress = server }
        if options.addsSamplePages { try SamplePages.addIfEmpty(to: store) }
        browser = PageBrowser(store: store)
        sync.onRemoteChange = { [browser] _ in browser.reload() }
    }
}
