import Attachments
import ControlCommands
import Foundation
import NotesCore
import Observation
import PageSharing
import Sync
import Synchronization

/// Ссылки на страницы для чтения (006): окно «Поделиться» и `mynotion page share`. Ссылки идут через сервер
/// синхронизации; снимок страницы публикуется сам после правки, сверка с сервером — при запуске и раз в 5 минут.
@MainActor
@Observable
final class ShareController: ShareControl {
    /// Ссылки, которые уже видело окно.
    private(set) var shares: [UUID: PageShare] = [:]
    private(set) var busyPageId: UUID?
    /// Ошибка последнего действия в окне.
    var errorMessage: String?

    @ObservationIgnored let publisher: SharePublisher
    @ObservationIgnored private let connection: ShareConnection
    @ObservationIgnored private weak var sync: SyncController?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(store: NotesStore, attachments: AttachmentStore, sync: SyncController) {
        self.sync = sync
        let viewState = BlockViewStateStore(database: store.database)
        let connection = ShareConnection()
        self.connection = connection
        publisher = SharePublisher(
            builder: SharedDocumentBuilder(store: store, collapsedBlockIds: { (try? viewState.collapsedBlockIds(ofPage: $0)) ?? [] }),
            shares: PageShareStore(database: store.database),
            fileURL: { attachments.fileURL(for: $0) },
            transport: { connection.transport })
        store.addWriteHook(publisher.changeWatcher)
    }

    /// Сверка при запуске и раз в 5 минут: другой Mac включил ссылку, снимок не ушёл из-за сети.
    func start() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshQuietly()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    var isAvailable: Bool {
        updateConnection()
        return connection.serverURL != nil
    }

    var serverURL: URL? { connection.serverURL }

    func url(of share: PageShare) -> URL? { serverURL.map(share.url(on:)) }

    // MARK: Окно «Поделиться»

    func load(_ pageId: UUID) async {
        errorMessage = nil
        if let share = try? await publisher.share(pageId) { shares[pageId] = share }
    }

    func setEnabled(_ enabled: Bool, pageId: UUID, includeSubpages: Bool? = nil) async {
        await perform(pageId) { try await self.publisher.setEnabled(enabled, pageId: pageId, includeSubpages: includeSubpages) }
    }

    func rotate(_ pageId: UUID) async {
        await perform(pageId) { try await self.publisher.rotate(pageId) }
    }

    private func perform(_ pageId: UUID, _ action: @escaping @MainActor () async throws -> PageShare) async {
        guard busyPageId == nil else { return }
        updateConnection()
        busyPageId = pageId
        errorMessage = nil
        defer { busyPageId = nil }
        do {
            shares[pageId] = try await action()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? SyncEngine.message(for: error)
        }
    }

    private func refreshQuietly() async {
        updateConnection()
        guard connection.serverURL != nil else { return }
        try? await publisher.refresh()
    }

    private func updateConnection() {
        connection.set(sync?.shareConnection())
    }

    // MARK: ShareControl (`mynotion page share`)

    func shareLink(of pageId: UUID) async throws -> ShareLinkState? {
        try await publisher.share(pageId).flatMap(state)
    }

    func setShareLink(of pageId: UUID, enabled: Bool, includeSubpages: Bool?) async throws -> ShareLinkState {
        updateConnection()
        let share = try await publisher.setEnabled(enabled, pageId: pageId, includeSubpages: includeSubpages)
        shares[pageId] = share
        return try require(state(share))
    }

    func rotateShareLink(of pageId: UUID) async throws -> ShareLinkState {
        updateConnection()
        let share = try await publisher.rotate(pageId)
        shares[pageId] = share
        return try require(state(share))
    }

    private func state(_ share: PageShare) -> ShareLinkState? {
        url(of: share).map {
            ShareLinkState(url: $0, enabled: share.enabled, includeSubpages: share.includeSubpages, isPublished: share.publishedDigest != nil)
        }
    }

    private func require(_ state: ShareLinkState?) throws -> ShareLinkState {
        guard let state else { throw SharePublisherError.syncNotConnected }
        return state
    }
}

/// Адрес сервера и ключ этого Mac для публикации вне главного потока.
final class ShareConnection: Sendable {
    private let value = Mutex<(serverURL: URL, deviceToken: String)?>(nil)

    func set(_ connection: (serverURL: URL, deviceToken: String)?) { value.withLock { $0 = connection } }

    var serverURL: URL? { value.withLock { $0?.serverURL } }

    var transport: (any SyncShareTransport)? {
        value.withLock { $0 }.map { HTTPSyncServer(url: $0.serverURL).shareTransport(deviceToken: $0.deviceToken) }
    }
}
