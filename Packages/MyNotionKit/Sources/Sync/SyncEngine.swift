import Foundation
import NotesCore
import Observation

/// Состояние для значка внизу боковой панели (FR-022).
public enum SyncStatus: Sendable, Hashable {
    /// Всё отправлено, свежие правки других Mac получены.
    case ready
    /// Есть неотправленные правки, идёт отправка.
    case sending
    /// Что-то мешает; правки ждут в очереди и уйдут сами, когда помеха пропадёт.
    case error(String)

    public var isError: Bool { if case .error = self { true } else { false } }
}

/// Сроки цикла синхронизации.
public struct SyncTiming: Sendable {
    /// Долгое ожидание новых пачек (research R9).
    public var longPollSeconds: Int
    /// Паузы между повторами после ошибки: первая, вторая, … и дальше последняя.
    public var retryDelays: [Duration]
    /// Сколько новых пачек журнала накопить до следующего снимка.
    public var snapshotEvery: Int
    /// Как часто спрашивать сервер о подтверждениях, чтобы стереть надгробия.
    public var tombstoneCheckInterval: Duration

    public static let standard = SyncTiming(longPollSeconds: 25, retryDelays: [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)],
                                            snapshotEvery: 1_000, tombstoneCheckInterval: .seconds(300))
    public static let fastForTests = SyncTiming(longPollSeconds: 25, retryDelays: [.milliseconds(50), .milliseconds(100), .milliseconds(200)],
                                                snapshotEvery: 1_000, tombstoneCheckInterval: .milliseconds(200))
}

/// Файлы рядом с циклом пачек (research R10): модуль вложений отправляет и докачивает их сам.
/// Цикл запускает работу, только когда её очередь не пуста, и не ждёт её: пачка с блоком уходит раньше файла.
public protocol SyncFileWork: AnyObject, Sendable {
    /// Есть ли что отправить или скачать сейчас; дёшево — спрашивается на каждом круге цикла.
    func hasPendingWork() -> Bool
    /// Работать, пока очередь не опустеет или не пропадёт связь.
    func run() async
}

/// Цикл синхронизации (T078): отправить очередь, дождаться пачек других Mac, применить, подтвердить.
/// Новая правка будит цикл сразу; без сети — повтор с паузой, правки ждут в очереди (FR-020).
@MainActor
@Observable
public final class SyncEngine {
    public private(set) var status: SyncStatus = .sending
    /// Когда последний раз всё сошлось с сервером.
    public private(set) var lastSyncedAt: Date?

    @ObservationIgnored public let store: NotesStore
    @ObservationIgnored public let applier: RemoteChangeApplier
    @ObservationIgnored let transport: any SyncTransport
    @ObservationIgnored let cipher: BatchCipher
    @ObservationIgnored let timing: SyncTiming
    @ObservationIgnored private let accounts: SyncAccountStore
    @ObservationIgnored private let outbox: Outbox
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Прервать текущее ожидание (долгий запрос или паузу перед повтором) — так `wake()` будит цикл.
    @ObservationIgnored private var cancelWaiting: (() -> Void)?
    @ObservationIgnored private var wakeRequested = false
    @ObservationIgnored private var enqueueObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lastTombstoneCheck: ContinuousClock.Instant?
    /// До какого номера сервер уже знает о применённом; `nil` — после запуска ещё не подтверждали.
    @ObservationIgnored private var ackedSeq: Int?
    /// Отправка и докачка файлов; ставит приложение.
    @ObservationIgnored public var fileWork: (any SyncFileWork)?
    @ObservationIgnored private var fileTask: Task<Void, Never>?
    /// Очередь, остановленная `stop()`, но ещё не вышедшая: новая ждёт её конца, чтобы две не шли разом.
    @ObservationIgnored private var stoppedFileTask: Task<Void, Never>?
    /// Номер текущей очереди: закончившаяся старая не сбрасывает новую.
    @ObservationIgnored private var fileTaskGeneration = 0
    /// Версия формата отправляемых пачек; меняют только тесты.
    @ObservationIgnored var formatVersionForTests: Int?

    public init(store: NotesStore, account: SyncAccount, transport: any SyncTransport, cipher: BatchCipher,
                applier: RemoteChangeApplier, timing: SyncTiming = .standard) {
        self.store = store
        self.transport = transport
        self.cipher = cipher
        self.applier = applier
        self.timing = timing
        accounts = SyncAccountStore(store: store)
        outbox = Outbox(store: store)
        _ = account
    }

    public func start() {
        guard loop == nil else { return }
        enqueueObserver = NotificationCenter.default.addObserver(forName: Outbox.didEnqueue, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        fileTask?.cancel()
        if let fileTask { stoppedFileTask = fileTask }
        fileTask = nil
        cancelWaiting?()
        cancelWaiting = nil
        if let enqueueObserver { NotificationCenter.default.removeObserver(enqueueObserver) }
        enqueueObserver = nil
    }

    /// Отправить и получить сейчас, не дожидаясь паузы.
    public func syncNow() {
        wake()
    }

    private func wake() {
        wakeRequested = true
        cancelWaiting?()
    }

    // MARK: Цикл

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            wakeRequested = false
            do {
                try await sendQueue()
                let isQueueEmpty = try outbox.isEmpty()
                if isQueueEmpty, !status.isError || failures == 0 { markReady() }
                startFileWorkIfNeeded()
                let hasMore = try await receive(wait: isQueueEmpty ? timing.longPollSeconds : 0)
                failures = 0
                startFileWorkIfNeeded()
                try await collectTombstonesIfDue()
                try await uploadSnapshotIfDue()
                if try outbox.isEmpty() { markReady() } else { status = .sending }
                if hasMore { continue }
            } catch where Task.isCancelled {
                return
            } catch let error where wakeRequested && Self.isCancellation(error) {
                continue
            } catch {
                status = .error(Self.message(for: error))
                failures += 1
                let delays = timing.retryDelays
                await pause(delays[min(failures, delays.count) - 1])
            }
        }
    }

    /// Файлы — своей задачей рядом с циклом, одна за раз; пустая очередь ничего не запускает.
    private func startFileWorkIfNeeded() {
        guard fileTask == nil, let fileWork, fileWork.hasPendingWork() else { return }
        fileTaskGeneration += 1
        let generation = fileTaskGeneration
        let previous = stoppedFileTask
        stoppedFileTask = nil
        fileTask = Task { [weak self] in
            await previous?.value
            if !Task.isCancelled { await fileWork.run() }
            guard let self, self.fileTaskGeneration == generation else { return }
            self.fileTask = nil
        }
    }

    /// Всё отправлено — кроме отложенных по размеру правок: о них значок говорит, пока их не сократят.
    private func markReady() {
        lastSyncedAt = Date()
        guard let pageId = try? outbox.setAsidePageIds().first else {
            status = .ready
            return
        }
        let title = (try? store.page(pageId))?.displayTitle ?? "Без названия"
        status = .error("Правка на странице «\(title)» больше 4 МБ и не уходит на другие Mac — сократите её. Остальные правки уходят")
    }

    /// Пауза, которую прерывает новая правка или `syncNow()`.
    private func pause(_ duration: Duration) async {
        guard !wakeRequested else { return }
        let task = Task { try? await Task.sleep(for: duration) }
        cancelWaiting = { task.cancel() }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        cancelWaiting = nil
    }

    /// Отправить очередь по порядку; принятая сервером пачка убирается из очереди.
    private func sendQueue() async throws {
        guard let account = try accounts.account() else { return }
        while true {
            let entries = try outbox.pendingEntries(limit: 20)
            guard !entries.isEmpty else { return try await sendServiceKeys(account: account) }
            status = .sending
            for entry in entries {
                let batchId = entry.id.uuidString.lowercased()
                let batch = SyncBatch(formatVersion: formatVersionForTests ?? SyncBatch.currentFormatVersion,
                                      deviceId: account.deviceId, deviceName: account.deviceName, changes: entry.changes)
                let seq: Int
                do {
                    seq = try await transport.postChanges(batchId: batchId, ciphertext: try cipher.seal(batch, batchId: batchId))
                } catch SyncServerError.tooLarge {
                    try outbox.setAside(entry)
                    continue
                }
                try outbox.remove(entry.id)
                try accounts.recordSent(seq: seq)
            }
        }
    }

    /// Ключи сервисов — своей пачкой без изменений записей, когда их отметили к отправке (ServiceKeys).
    /// Связка ключей читается не на главном потоке: вопрос macOS о доступе не останавливает окно.
    private func sendServiceKeys(account: SyncAccount) async throws {
        guard let keys = applier.serviceKeys, let pending = try ServiceKeys.pending(in: store) else { return }
        let store = store
        let current = try await Task.detached(priority: .userInitiated) { try ServiceKeys.current(keys: keys, in: store) }.value
        if !current.isEmpty || pending.request != nil {
            status = .sending
            let batchId = UUID.timeOrdered().uuidString.lowercased()
            let batch = SyncBatch(formatVersion: formatVersionForTests ?? SyncBatch.currentFormatVersion,
                                  deviceId: account.deviceId, deviceName: account.deviceName, changes: [],
                                  serviceKeys: current.isEmpty ? nil : current, requestsServiceKeys: pending.request == nil ? nil : true)
            let seq = try await transport.postChanges(batchId: batchId, ciphertext: try cipher.seal(batch, batchId: batchId))
            try accounts.recordSent(seq: seq)
        }
        try ServiceKeys.didSend(pending, in: store)
    }

    /// Одна порция журнала: применить пачки других Mac по порядку и подтвердить. `true` — на сервере есть ещё.
    private func receive(wait: Int) async throws -> Bool {
        guard let account = try accounts.account() else { return false }
        // Потерянное раньше подтверждение — до долгого ожидания: без новых пачек оно иначе ждало бы до 25 с.
        try await acknowledgePulled()
        let page: SyncChangesPage
        do {
            page = try await interruptibly { [transport] in try await transport.changes(after: account.lastPulledSeq, wait: wait) }
        } catch SyncServerError.logCompacted {
            try await restoreFromSnapshot()
            return true
        }
        guard !page.items.isEmpty else { return false }

        var pending: [ReceivedBatch] = []
        var failure: (any Error)?
        for item in page.items {
            if item.deviceId == account.deviceId {
                try applier.apply(pending)
                pending.removeAll()
                try accounts.recordPulled(seq: item.seq)
                continue
            }
            do {
                let batch = try cipher.open(item.ciphertext, batchId: item.batchId, deviceId: item.deviceId)
                pending.append(ReceivedBatch(seq: item.seq, batchId: item.batchId, batch: batch))
            } catch {
                // Пачку нельзя применить — она и всё после неё ждут; применённое до неё остаётся.
                failure = error
                break
            }
        }
        try applier.apply(pending)
        try await acknowledgePulled()
        if let failure { throw failure }
        return page.hasMore
    }

    /// Подтвердить применённое. Подтверждение, потерянное по дороге, уходит на следующем круге и без новых пачек.
    private func acknowledgePulled() async throws {
        guard let pulled = try accounts.account()?.lastPulledSeq, pulled > (ackedSeq ?? 0) else { return }
        try await transport.ack(pulled)
        ackedSeq = pulled
    }

    /// Журнал до нашего номера сжат: начать со снимка.
    private func restoreFromSnapshot() async throws {
        guard let envelope = try await transport.snapshot() else { throw SyncServerError.notFound }
        let snapshot = try cipher.openSnapshot(envelope.ciphertext, seq: envelope.seq)
        try applier.apply(snapshot)
        try await transport.ack(envelope.seq)
        ackedSeq = envelope.seq
    }

    /// Выложить снимок всех записей на момент последней применённой пачки — после него сервер сожмёт журнал.
    public func uploadSnapshot() async throws {
        guard let account = try accounts.account(), try outbox.isEmpty(), account.lastPulledSeq >= account.lastSentSeq,
              account.lastPulledSeq > 0 else { return }
        var serviceKeys: [ServiceKeyChange]?
        if let keys = applier.serviceKeys {
            let store = store
            serviceKeys = try await Task.detached(priority: .userInitiated) { try ServiceKeys.current(keys: keys, in: store) }.value
        }
        let snapshot = try SyncSnapshot.make(seq: account.lastPulledSeq, from: store, serviceKeys: serviceKeys)
        do {
            try await transport.putSnapshot(seq: snapshot.seq, ciphertext: try cipher.sealSnapshot(snapshot))
        } catch SyncServerError.badRequest {
            // Другой Mac уже выложил снимок новее — этот не нужен.
        }
        try accounts.recordSnapshot(seq: snapshot.seq)
    }

    private func uploadSnapshotIfDue() async throws {
        guard let account = try accounts.account(),
              account.lastPulledSeq - account.lastSnapshotSeq >= timing.snapshotEvery else { return }
        try await uploadSnapshot()
    }

    private func collectTombstonesIfDue() async throws {
        let now = ContinuousClock.now
        if let last = lastTombstoneCheck, now - last < timing.tombstoneCheckInterval { return }
        let collector = TombstoneCollector(store: store)
        guard try collector.hasMarks(), try outbox.isEmpty() else { return }
        lastTombstoneCheck = now
        try collector.collect(deviceAcks: try await transport.devices().map(\.lastAckSeq))
    }

    /// Запрос, который можно прервать новой правкой: тогда цикл сразу идёт отправлять.
    private func interruptibly<T: Sendable>(_ request: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await request() }
        cancelWaiting = { task.cancel() }
        defer { cancelWaiting = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    // MARK: Сообщения

    nonisolated private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    nonisolated public static func message(for error: any Error) -> String {
        if error is URLError {
            return "Нет связи — правки сохранены на этом Mac и уйдут сами, когда связь вернётся"
        }
        if let cipherError = error as? BatchCipherError { return cipherError.localizedDescription }
        if let serverError = error as? SyncServerError { return serverError.localizedDescription }
        if let setupError = error as? SyncSetupError { return setupError.localizedDescription }
        if let codeError = error as? JoinCodeError { return codeError.localizedDescription }
        return "Не получилось принять правки с другого Mac: \(SaveStatus.reason(for: error)). Попробую ещё раз сам"
    }

}
