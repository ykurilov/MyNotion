import Foundation
import NotesCore
import Sync
import Synchronization

/// Ссылки на страницы: включить, выключить, сменить — на сервере; снимок страницы публикуется сам, через пару секунд
/// после правки. Ошибка сети не теряет правку: снимок помечен неопубликованным и уйдёт при следующей сверке.
public actor SharePublisher {
    private let builder: SharedDocumentBuilder
    private let shares: PageShareStore
    private let fileURL: @Sendable (UUID) -> URL?
    private let transport: @Sendable () -> (any SyncShareTransport)?
    private let delay: Duration
    private let retryDelay: Duration

    /// Ссылка → страницы и строки баз её последнего снимка.
    private var watched: [UUID: Set<UUID>] = [:]
    private var pendingIds: Set<UUID> = []
    private var pendingDatabases = false
    /// Ссылки, чья публикация (или закрытие — страница ушла в корзину) не дошла до сервера: повтор с нарастающей паузой.
    private var failedIds: Set<UUID> = []
    private var retryAttempt = 0
    private var flushTask: Task<Void, Never>?
    private var publishing: Set<UUID> = []
    private var publishAgain: Set<UUID> = []
    /// Правки, о которых подписчик уже узнал, а актор ещё нет (тесты ждут и их).
    private nonisolated let undelivered = Mutex(0)
    /// Последняя ошибка публикации по ссылке — для окна «Поделиться».
    public private(set) var lastErrors: [UUID: String] = [:]

    public init(builder: SharedDocumentBuilder, shares: PageShareStore, fileURL: @escaping @Sendable (UUID) -> URL?,
                transport: @escaping @Sendable () -> (any SyncShareTransport)?, delay: Duration = .seconds(2),
                retryDelay: Duration = .seconds(15)) {
        self.builder = builder
        self.shares = shares
        self.fileURL = fileURL
        self.transport = transport
        self.delay = delay
        self.retryDelay = retryDelay
    }

    /// Подписчик записи: отмечает затронутые страницы, публикация — после паузы, вне транзакции.
    public nonisolated var changeWatcher: any NotesWriteHook {
        ShareChangeWatcher { [weak self] ids, databases in
            guard let self else { return }
            undelivered.withLock { $0 += 1 }
            Task { await self.noteChanges(ids, databases: databases) }
        }
    }

    // MARK: Управление

    public func share(_ pageId: UUID) throws -> PageShare? {
        try shares.share(pageId)
    }

    /// Включить или выключить ссылку. Включение сразу кладёт снимок.
    @discardableResult
    public func setEnabled(_ enabled: Bool, pageId: UUID, includeSubpages: Bool? = nil) async throws -> PageShare {
        let transport = try requireTransport()
        let remote = try await transport.setShare(pageId, enabled: enabled, includeSubpages: includeSubpages)
        try shares.save(remote)
        if enabled {
            try await publish(pageId)
        } else {
            watched[pageId] = nil
            lastErrors[pageId] = nil
        }
        return try shares.share(pageId)!
    }

    /// Новая ссылка; снимок остаётся тем же.
    @discardableResult
    public func rotate(_ pageId: UUID) async throws -> PageShare {
        let remote = try await requireTransport().rotateShare(pageId)
        try shares.save(remote)
        try shares.setPublishedDigest(remote.digest, of: pageId)
        return try shares.share(pageId)!
    }

    /// Сверка с сервером (запуск, раз в несколько минут, другой Mac включил ссылку): список ссылок и все
    /// неопубликованные снимки.
    public func refresh() async throws {
        let remote = try await requireTransport().shares()
        try shares.replaceAll(with: remote)
        for share in try shares.all() where share.enabled {
            do {
                try await publish(share.pageId)
            } catch {
                lastErrors[share.pageId] = error.localizedDescription
            }
        }
    }

    // MARK: Публикация

    /// Положить снимок, если он изменился, и догрузить его файлы. Страница в корзине — ссылка выключается.
    public func publish(_ pageId: UUID) async throws {
        guard publishing.insert(pageId).inserted else {
            publishAgain.insert(pageId)
            return
        }
        defer { publishing.remove(pageId) }
        repeat {
            publishAgain.remove(pageId)
            try await publishOnce(pageId)
        } while publishAgain.contains(pageId)
    }

    private func publishOnce(_ pageId: UUID) async throws {
        guard let share = try shares.share(pageId), share.enabled, let transport = transport() else { return }
        guard let publication = try builder.build(rootPageId: pageId, includeSubpages: share.includeSubpages) else {
            _ = try await setEnabled(false, pageId: pageId)
            return
        }
        watched[pageId] = publication.watchedIds
        guard publication.digest != share.publishedDigest else { return }
        do {
            let missing = try await transport.publishShare(pageId, digest: publication.digest, document: publication.data)
            var complete = true
            for fileId in missing {
                guard let url = fileURL(fileId) else {
                    complete = false
                    continue
                }
                try await transport.putShareFile(pageId, fileId: fileId, contentsOf: url)
            }
            try shares.setPublishedDigest(complete ? publication.digest : nil, of: pageId)
            lastErrors[pageId] = nil
        } catch SyncServerError.shareDisabled {
            // выключили на другом Mac
            try await refresh()
        } catch {
            lastErrors[pageId] = error.localizedDescription
            throw error
        }
    }

    private func noteChanges(_ ids: Set<UUID>, databases: Bool) {
        undelivered.withLock { $0 -= 1 }
        pendingIds.formUnion(ids)
        pendingDatabases = pendingDatabases || databases
        scheduleFlush(after: delay)
    }

    private func scheduleFlush(after pause: Duration) {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: pause)
            await self.flush()
        }
    }

    private func flush() async {
        flushTask = nil
        let ids = pendingIds
        let databases = pendingDatabases
        pendingIds = []
        pendingDatabases = false
        guard let enabled = try? shares.all().filter(\.enabled) else { return }
        var failed: Set<UUID> = []
        for share in enabled {
            let scope = watched[share.pageId]
            // снимок ещё не собирался на этом запуске — проверим по digest, ничего не теряя
            let touched = failedIds.contains(share.pageId)
                || scope.map { !$0.isDisjoint(with: ids) || (databases && !$0.isEmpty) } ?? true
            guard touched else { continue }
            do {
                try await publish(share.pageId)
            } catch {
                failed.insert(share.pageId)
            }
        }
        failedIds = failed
        if failed.isEmpty {
            retryAttempt = 0
        } else {
            // 15 с, 30 с, минута… не реже раза в 4 минуты; сверка раз в 5 минут и запуск — ещё одна страховка
            retryAttempt += 1
            scheduleFlush(after: retryDelay * (1 << min(retryAttempt - 1, 4)))
        }
    }

    /// Дождаться отложенной публикации (тесты).
    public func waitForPendingPublications() async {
        while true {
            if let task = flushTask {
                await task.value
            } else if undelivered.withLock({ $0 }) > 0 {
                await Task.yield()
            } else {
                return
            }
        }
    }

    private func requireTransport() throws -> any SyncShareTransport {
        guard let transport = transport() else { throw SharePublisherError.syncNotConnected }
        return transport
    }
}

public enum SharePublisherError: Error, LocalizedError, Equatable {
    case syncNotConnected

    public var errorDescription: String? {
        switch self {
        case .syncNotConnected: "Ссылки работают через сервер синхронизации — сначала подключите его в настройках"
        }
    }
}

/// Что в записи может поменять снимки: страницы (и их родители — новая подстраница), блоки, строки и схемы баз.
struct ShareChangeWatcher: NotesWriteHook {
    let onChange: @Sendable (Set<UUID>, Bool) -> Void

    func notesWillCommit(_ changes: NotesChanges, in transaction: NotesTransaction) throws {
        var ids: Set<UUID> = []
        for change in changes.pages where !change.changedFields.isSubset(of: Page.Field.bookkeeping) || change.isNew {
            ids.insert(change.page.id)
            if let parentId = change.page.parentId { ids.insert(parentId) }
        }
        for change in changes.blocks {
            switch change {
            case .saved(let block, _, _): ids.insert(block.pageId)
            case .erased(_, let pageId): ids.insert(pageId)
            }
        }
        ids.formUnion(changes.erasedPageIds)
        let database = changes.database
        ids.formUnion(database.cells.map(\.rowId))
        ids.formUnion(database.relationLinks.map(\.record.rowId))
        ids.formUnion(database.databases.map(\.record.pageId))
        ids.formUnion(database.properties.map(\.record.databaseId))
        ids.formUnion(database.views.map(\.record.databaseId))
        let schemaOnly = !database.options.isEmpty || !database.rowOrders.isEmpty
        guard !ids.isEmpty || schemaOnly else { return }
        onChange(ids, schemaOnly)
    }
}
