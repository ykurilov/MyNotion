import Foundation
import NotesCore
import Sync
import Synchronization
import Testing
@testable import PageSharing

/// Публикация ссылки: что и когда уходит на сервер.
@Suite("Публикация ссылки")
struct SharePublisherTests {
    let library: SharingLibrary
    let server = FakeShareServer()

    init() throws {
        library = try SharingLibrary()
    }

    private func publisher(localFiles: Set<UUID>? = nil, connected: Bool = true) -> SharePublisher {
        let server = server
        let folder = library.folder
        let publisher = SharePublisher(
            builder: SharedDocumentBuilder(store: library.store, collapsedBlockIds: { _ in [] }),
            shares: PageShareStore(database: library.database),
            fileURL: { id in localFiles.map { $0.contains(id) } ?? true ? folder.appendingPathComponent(id.uuidString) : nil },
            transport: { connected ? server : nil },
            delay: .milliseconds(20))
        library.store.addWriteHook(publisher.changeWatcher)
        return publisher
    }

    @Test("Включение кладёт снимок и догружает его файлы")
    func enablingPublishesDocumentAndFiles() async throws {
        let publisher = publisher()
        let share = try await publisher.setEnabled(true, pageId: library.root, includeSubpages: false)
        #expect(share.enabled)
        #expect(server.documents.count == 1)
        #expect(server.uploadedFiles == [library.image.id])
        #expect(share.publishedDigest == server.digest(of: library.root))
    }

    @Test("Без правок снимок второй раз не отправляется")
    func unchangedDocumentIsNotResent() async throws {
        let publisher = publisher()
        try await publisher.setEnabled(true, pageId: library.root, includeSubpages: false)
        try await publisher.publish(library.root)
        try await publisher.refresh()
        #expect(server.documents.count == 1)
    }

    @Test("Правка в снимке публикуется сама, правка снаружи — нет")
    func editsInScopeRepublish() async throws {
        let publisher = publisher()
        try await publisher.setEnabled(true, pageId: library.root, includeSubpages: false)
        try library.appendParagraph("Вне снимка", to: library.privatePage)
        await publisher.waitForPendingPublications()
        #expect(server.documents.count == 1)
        try library.setText("Новый текст", ofFirstBlockOn: library.root)
        await publisher.waitForPendingPublications()
        #expect(server.documents.count == 2)
        #expect(String(decoding: server.documents.last!, as: UTF8.self).contains("Новый текст"))
    }

    @Test("Файла нет на этом Mac — снимок остаётся неопубликованным до следующей сверки")
    func missingLocalFileKeepsDigestOpen() async throws {
        let publisher = publisher(localFiles: [])
        let share = try await publisher.setEnabled(true, pageId: library.root, includeSubpages: false)
        #expect(share.publishedDigest == nil)
        #expect(server.uploadedFiles.isEmpty)
    }

    @Test("Выключение и страница в корзине выключают ссылку на сервере")
    func disableAndTrash() async throws {
        let publisher = publisher()
        try await publisher.setEnabled(true, pageId: library.root, includeSubpages: false)
        let off = try await publisher.setEnabled(false, pageId: library.root)
        #expect(!off.enabled)
        #expect(server.isEnabled(library.root) == false)

        try await publisher.setEnabled(true, pageId: library.child, includeSubpages: true)
        #expect(server.isEnabled(library.child) == true)
        try library.trash(library.child)
        await publisher.waitForPendingPublications()
        #expect(server.isEnabled(library.child) == false)
    }

    @Test("Повторное включение — та же ссылка, смена — новая")
    func reenableKeepsTokenRotateChangesIt() async throws {
        let publisher = publisher()
        let first = try await publisher.setEnabled(true, pageId: library.root)
        try await publisher.setEnabled(false, pageId: library.root)
        let again = try await publisher.setEnabled(true, pageId: library.root)
        #expect(again.token == first.token)
        let rotated = try await publisher.rotate(library.root)
        #expect(rotated.token != first.token)
    }

    @Test("Без синхронизации — понятная ошибка")
    func withoutSyncThrows() async throws {
        let publisher = publisher(connected: false)
        await #expect(throws: SharePublisherError.syncNotConnected) {
            try await publisher.setEnabled(true, pageId: library.root)
        }
    }
}

/// Сервер ссылок в памяти: те же правила, что у настоящего (contracts/share-api.md).
final class FakeShareServer: SyncShareTransport, @unchecked Sendable {
    private struct State {
        var shares: [UUID: SyncShare] = [:]
        var documents: [Data] = []
        var files: Set<UUID> = []
        var uploads: [UUID] = []
        var neededFiles: [UUID: [UUID]] = [:]
    }

    private let state = Mutex(State())

    var documents: [Data] { state.withLock { $0.documents } }
    var uploadedFiles: [UUID] { state.withLock { $0.uploads } }
    func isEnabled(_ pageId: UUID) -> Bool? { state.withLock { $0.shares[pageId]?.enabled } }
    func digest(of pageId: UUID) -> String? { state.withLock { $0.shares[pageId]?.digest } }

    func shares() async throws -> [SyncShare] { state.withLock { Array($0.shares.values) } }

    func setShare(_ pageId: UUID, enabled: Bool, includeSubpages: Bool?) async throws -> SyncShare {
        state.withLock { state in
            let old = state.shares[pageId]
            let share = SyncShare(pageId: pageId, token: old?.token ?? UUID().uuidString, enabled: enabled,
                                  includeSubpages: includeSubpages ?? old?.includeSubpages ?? true,
                                  digest: enabled ? old?.digest : nil, publishedAt: nil)
            state.shares[pageId] = share
            return share
        }
    }

    func rotateShare(_ pageId: UUID) async throws -> SyncShare {
        try state.withLock { state in
            guard let old = state.shares[pageId] else { throw SyncServerError.shareDisabled }
            let share = SyncShare(pageId: pageId, token: UUID().uuidString, enabled: old.enabled, includeSubpages: old.includeSubpages,
                                  digest: old.digest, publishedAt: old.publishedAt)
            state.shares[pageId] = share
            return share
        }
    }

    func deleteShare(_ pageId: UUID) async throws {
        _ = state.withLock { $0.shares.removeValue(forKey: pageId) }
    }

    func publishShare(_ pageId: UUID, digest: String, document: Data) async throws -> [UUID] {
        let fileIds = try JSONDecoder().decode(SharedDocument.self, from: document).files.compactMap { UUID(uuidString: $0.id) }
        return try state.withLock { state in
            guard let old = state.shares[pageId], old.enabled else { throw SyncServerError.shareDisabled }
            state.documents.append(document)
            state.shares[pageId] = SyncShare(pageId: pageId, token: old.token, enabled: true, includeSubpages: old.includeSubpages,
                                             digest: digest, publishedAt: 1)
            return fileIds.filter { !state.files.contains($0) }
        }
    }

    func putShareFile(_ pageId: UUID, fileId: UUID, contentsOf url: URL) async throws {
        state.withLock { state in
            state.files.insert(fileId)
            state.uploads.append(fileId)
        }
    }
}
