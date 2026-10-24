import Attachments
import ControlProtocol
import Foundation
import Synchronization
@testable import ControlCommands
@testable import NotesCore
@testable import PageVersions

/// Пустая папка на время теста; стирается вместе с объектом.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotionControlTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var databaseURL: URL { url.appendingPathComponent("MyNotion.sqlite") }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Часы теста: идут только по `advance`.
final class ManualClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { current.withLock { $0 } }
    var reading: @Sendable () -> Date { { [self] in now } }

    func advance(minutes: Double) {
        current.withLock { $0 = $0.addingTimeInterval(minutes * 60) }
    }
}

/// Записи версий по расписанию тесту не нужны: проверки «пора ли» не идут.
struct NeverScheduler: VersionRecordingScheduler {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {}
}

/// Подставное окно: одна вкладка с `currentPageId`.
@MainActor
final class FakeWindowControl: WindowControl {
    var currentPageId: UUID?

    func windows() -> [WindowInfo] {
        [WindowInfo(index: 1, isFront: true, tabs: [TabInfo(index: 1, pageId: currentPageId, title: "", isSelected: true)],
                    canGoBack: false, canGoForward: false, isBusy: false)]
    }
}

/// Журнал команд в память.
final class RecordingLog: CommandLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CommandLogEntry] = []

    func record(_ entry: CommandLogEntry) {
        lock.withLock { stored.append(entry) }
    }

    var entries: [CommandLogEntry] { lock.withLock { stored } }
}

/// Хост на временной базе с настоящими операциями.
@MainActor
final class TestHost: ControlHost {
    let folder: TemporaryFolder
    let store: NotesStore
    let attachments: AttachmentStore
    let openDocuments: OpenDocuments
    let versions: PageVersionStore
    let versionRecorder: PageVersionRecorder
    let clock = ManualClock()
    let window = FakeWindowControl()
    var windowControl: any WindowControl { window }
    var transferControl: (any TransferControl)? { nil }
    var appInfo: AppInfo { AppInfo(version: "1.0", build: "1", databasePath: folder.databaseURL.path, socketPath: "/tmp/test.sock") }
    var now: Date { clock.now }
    private(set) var treeChanges: [Set<UUID>] = []
    private(set) var directWrites: [Set<UUID>] = []
    /// Иконка и обложка идут лёгким путём окна: страница не перечитывается, курсор Юрия остаётся на месте.
    private(set) var iconChanges: [UUID] = []
    private(set) var appearanceChanges: [UUID] = []

    init() throws {
        folder = try TemporaryFolder()
        store = NotesStore(database: try AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        attachments = AttachmentStore(store: store, folder: folder.url.appendingPathComponent("Attachments", isDirectory: true))
        openDocuments = OpenDocuments(store: store)
        versions = PageVersionStore(store: store)
        versionRecorder = PageVersionRecorder(store: store, versions: versions, now: clock.reading, scheduler: NeverScheduler())
        versionRecorder.installDueMarker(localDeviceName: "Тестовый Mac")
    }

    func treeDidChange(_ pageIds: Set<UUID>) { treeChanges.append(pageIds) }
    func iconDidChange(_ pageId: UUID) { iconChanges.append(pageId) }
    func appearanceDidChange(_ pageId: UUID) { appearanceChanges.append(pageId) }
    func refreshAfterDirectWrite(pages: Set<UUID>) { directWrites.append(pages) }

    /// Страница с абзацами.
    @discardableResult
    func page(_ title: String, parent: UUID? = nil, texts: [String] = []) throws -> Page {
        try store.write { tx in
            let page = try tx.createPage(title: title, parentId: parent)
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            for text in texts {
                key = .between(key, nil)
                try tx.insertBlock(Block(pageId: page.id, text: InlineText(text), sortKey: key!))
            }
            return page
        }
    }

    func stored(_ pageId: UUID) throws -> Page? {
        try store.write { try $0.page(pageId) }
    }

    func texts(_ pageId: UUID) throws -> [String] {
        try store.pageContent(pageId)?.blocks.map(\.text.string) ?? []
    }
}
