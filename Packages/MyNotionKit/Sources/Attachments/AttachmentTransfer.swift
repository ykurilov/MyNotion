import Foundation
import GRDB
import NotesCore
import Sync

/// Отправка и докачка файлов через сервер (research R10, contracts/sync-and-files-api.md «Поведение Mac»).
///
/// - Отправка: части по одной, повтор с первой части, которой нет на сервере (`GET /files/{id}`), затем `complete`.
/// - Скачивание: по одному файлу, файлы открытой страницы — первыми; части пишутся во временный файл, после последней
///   сверяется SHA-256. `409 file_incomplete` и `404` — повтор через 1, 2, 4 … 60 мин, надпись «Ждёт отправки с другого Mac».
/// - `507` — «Кончилось место для файлов, общих для ваших Mac — новые файлы пока ждут на этом Mac», повтор раз в час; файл на Mac не трогается.
/// - Другой сбой одного файла (копию не прочитать, сервер отказал именно ему) — запись `failed`, повтор через те же
///   1, 2, 4 … 60 мин; остальные файлы идут своим чередом. Только обрыв связи останавливает всю очередь.
///
/// `runDue()` делает то, что пора сейчас, и говорит, когда пора в следующий раз: время не идёт внутри, его ведёт
/// вызывающий (`AttachmentSyncWork`), а тесты — своими часами.
public actor AttachmentTransfer {
    public static let waitingForOtherMac = "Ждёт отправки с другого Mac"
    public static let storageFullMessage = "Кончилось место для файлов, общих для ваших Mac — новые файлы пока ждут на этом Mac"
    /// Паузы перед повтором скачивания файла, которого ещё нет на сервере.
    static let waitingDelays: [TimeInterval] = [1, 2, 4, 8, 16, 32, 60].map { $0 * 60 }
    static let storageFullDelay: TimeInterval = 3_600
    /// Надписи записей `failed`, которые повторяются сами; остальные `failed` (копирование, нет копии) — нет.
    public static let uploadFailedMessage = "Не удалось отправить файл на другие Mac — попробую ещё раз сам"
    public static let downloadFailedMessage = "Не удалось скачать файл — попробую ещё раз сам"
    public static let missingCopyMessage = "Копии файла нет на этом Mac — вставьте файл ещё раз"
    static var retriedDownloadMessages: [String] { [downloadFailedMessage, AttachmentError.damaged.localizedDescription] }

    let attachments: AttachmentStore
    let transport: any SyncFileTransport
    let cipher: FileCipher
    let now: @Sendable () -> Date
    private var priority: [UUID] = []
    /// Пауза записи: файл ещё не на сервере или на нём сломалась отправка или скачивание.
    private var waiting: [UUID: (attempts: Int, dueAt: Date)] = [:]
    private var storageFullUntil: Date?
    /// Сообщение для значка синхронизации; `nil` — всё в порядке.
    public private(set) var notice: String?
    private var onNotice: (@Sendable (String?) -> Void)?

    public init(attachments: AttachmentStore, transport: any SyncFileTransport, cipher: FileCipher,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.attachments = attachments
        self.transport = transport
        self.cipher = cipher
        self.now = now
    }

    public func setNoticeHandler(_ handler: @escaping @Sendable (String?) -> Void) {
        onNotice = handler
    }

    /// Эти файлы — в начало очереди скачивания (открытая страница), и не ждать паузы.
    public func prioritize(_ ids: [UUID]) {
        priority = ids + priority.filter { !ids.contains($0) }
        for id in ids { waiting[id] = nil }
    }

    /// Сделать всё, что пора. `nil` — очередь пуста; иначе — когда пора снова. Обрыв связи — ошибка: сделанное
    /// сохранено, повтор продолжит с места обрыва.
    public func runDue() async throws -> Date? {
        try await uploadDue()
        try await downloadDue()
        return try nextDueDate()
    }

    // MARK: Отправка

    private func uploadDue() async throws {
        if let until = storageFullUntil, now() < until { return }
        for record in try pendingUploads() {
            if let wait = waiting[record.id], now() < wait.dueAt { continue }
            do {
                try await upload(record)
                waiting[record.id] = nil
            } catch SyncServerError.storageFull {
                storageFullUntil = now().addingTimeInterval(Self.storageFullDelay)
                setNotice(Self.storageFullMessage)
                return
            } catch where Self.isConnectionLoss(error) {
                throw error
            } catch {
                try pauseAfterFailure(record.id, message: Self.uploadFailedMessage)
            }
        }
        storageFullUntil = nil
        if notice == Self.storageFullMessage { setNotice(nil) }
    }

    private func pendingUploads() throws -> [AttachmentRecord] {
        try attachments.records(sql: """
            SELECT * FROM attachment WHERE orphanedAt IS NULL
                AND (state IN ('local', 'uploading') OR (state = 'failed' AND localPath IS NOT NULL AND lastError = ?))
            ORDER BY id
            """, arguments: [Self.uploadFailedMessage])
    }

    private func upload(_ record: AttachmentRecord) async throws {
        guard let localPath = record.localPath else {
            // Отправлять нечего: без пометки запись брала бы очередь на каждом круге.
            try attachments.update(record.id) {
                $0.state = .failed
                $0.lastError = Self.missingCopyMessage
            }
            return
        }
        let url = attachments.folder.appendingPathComponent(localPath)
        let ref = record.ref
        try attachments.update(ref.id) { $0.state = .uploading }
        let status = try await transport.fileStatus(ref.id)
        if status?.complete != true {
            let present = status?.partCount == ref.partCount ? Set(status?.parts ?? []) : []
            try attachments.update(ref.id) { $0.uploadedParts = present }
            for index in 0..<ref.partCount where !present.contains(index) {
                try Task.checkCancellation()
                let part = try cipher.sealPart(ofFileAt: url, index: index, ref: ref)
                try await transport.putFilePart(ref.id, index: index, count: ref.partCount, data: part)
                try attachments.update(ref.id) { $0.uploadedParts.insert(index) }
            }
            do {
                try await transport.completeFile(ref.id, partCount: ref.partCount)
            } catch SyncServerError.fileComplete {
                // Уже собран — повтор после обрыва ответа.
            }
        }
        try attachments.update(ref.id) {
            $0.state = .uploaded
            $0.uploadedParts = Set(0..<ref.partCount)
            $0.lastError = nil
        }
    }

    // MARK: Скачивание

    private func downloadDue() async throws {
        let pending = try pendingDownloads()
        let order = priority.filter { id in pending.contains { $0.id == id } } + pending.map(\.id).filter { !priority.contains($0) }
        for id in order {
            if let wait = waiting[id], now() < wait.dueAt { continue }
            guard let record = pending.first(where: { $0.id == id }) else { continue }
            do {
                try await download(record)
                waiting[id] = nil
                priority.removeAll { $0 == id }
            } catch SyncServerError.fileIncomplete, SyncServerError.notFound {
                let attempts = (waiting[id]?.attempts ?? 0) + 1
                let delay = Self.waitingDelays[min(attempts, Self.waitingDelays.count) - 1]
                waiting[id] = (attempts, now().addingTimeInterval(delay))
                try attachments.update(id) {
                    $0.state = .remote
                    $0.lastError = Self.waitingForOtherMac
                }
                attachments.postAvailabilityChange(id)
            } catch AttachmentError.damaged, FileCipherError.tampered {
                try? FileManager.default.removeItem(at: temporaryURL(for: record.ref))
                try pauseAfterFailure(id, message: AttachmentError.damaged.localizedDescription) { $0.downloadedParts = [] }
                attachments.postAvailabilityChange(id)
            } catch where Self.isConnectionLoss(error) {
                throw error
            } catch {
                try pauseAfterFailure(id, message: Self.downloadFailedMessage)
                attachments.postAvailabilityChange(id)
            }
        }
    }

    private func pendingDownloads() throws -> [AttachmentRecord] {
        let retried = Self.retriedDownloadMessages
        return try attachments.records(sql: """
            SELECT * FROM attachment WHERE orphanedAt IS NULL
                AND (state IN ('remote', 'downloading')
                     OR (state = 'failed' AND localPath IS NULL AND lastError IN (\(retried.map { _ in "?" }.joined(separator: ", ")))))
            ORDER BY id
            """, arguments: StatementArguments(retried))
    }

    private func download(_ record: AttachmentRecord) async throws {
        let ref = record.ref
        let directory = attachments.directory(for: ref.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = temporaryURL(for: ref)
        var downloaded = record.downloadedParts
        if downloaded.isEmpty || !FileManager.default.fileExists(atPath: temporary.path) {
            downloaded = []
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
        }
        try attachments.update(ref.id) {
            $0.state = .downloading
            $0.downloadedParts = downloaded
        }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        for index in 0..<ref.partCount where !downloaded.contains(index) {
            try Task.checkCancellation()
            let sealed = try await transport.filePart(ref.id, index: index)
            let plaintext = try cipher.open(sealed, fileId: ref.id, index: index, count: ref.partCount)
            try handle.seek(toOffset: UInt64(index * AttachmentRef.partSize))
            try handle.write(contentsOf: plaintext)
            try attachments.update(ref.id) { $0.downloadedParts.insert(index) }
        }
        try handle.truncate(atOffset: UInt64(ref.byteCount))
        try handle.close()
        guard try FileDigest.sha256(of: temporary) == ref.sha256 else { throw AttachmentError.damaged }

        let name = AttachmentStore.safeFileName(ref.name)
        let destination = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        FileQuarantine.mark(destination)
        try attachments.update(ref.id) {
            $0.localPath = "\(ref.id.attachmentKey)/\(name)"
            $0.state = .uploaded
            $0.downloadedParts = Set(0..<ref.partCount)
            $0.lastError = nil
        }
        attachments.postAvailabilityChange(ref.id)
    }

    /// Недокачанный файл — скрытый, рядом с будущей копией.
    private func temporaryURL(for ref: AttachmentRef) -> URL {
        attachments.directory(for: ref.id).appendingPathComponent(".download")
    }

    // MARK: Срок

    /// Сбой одного файла: запись `failed` с надписью, повтор после паузы 1, 2, 4 … 60 мин.
    private func pauseAfterFailure(_ id: UUID, message: String, _ change: (inout AttachmentRecord) -> Void = { _ in }) throws {
        let attempts = (waiting[id]?.attempts ?? 0) + 1
        let delay = Self.waitingDelays[min(attempts, Self.waitingDelays.count) - 1]
        waiting[id] = (attempts, now().addingTimeInterval(delay))
        try attachments.update(id) {
            $0.state = .failed
            $0.lastError = message
            change(&$0)
        }
    }

    /// Связи нет или этот Mac больше не пускают: дальше идти бессмысленно, очередь запустится на следующем круге.
    static func isConnectionLoss(_ error: any Error) -> Bool {
        error is URLError || error is CancellationError || (error as? SyncServerError) == .unauthorized
    }

    private func nextDueDate() throws -> Date? {
        var dates: [Date] = []
        for record in try pendingUploads() {
            dates.append(max(storageFullUntil ?? now(), waiting[record.id]?.dueAt ?? now()))
        }
        for record in try pendingDownloads() {
            dates.append(waiting[record.id]?.dueAt ?? now())
        }
        return dates.min()
    }

    private func setNotice(_ text: String?) {
        guard notice != text else { return }
        notice = text
        onNotice?(text)
    }
}

/// Очередь файлов в цикле синхронизации (`SyncEngine.fileWork`): работает, пока есть что отправить, скачать или стереть,
/// и спит до ближайшего срока. Новая работа (вставка файла, блок с другого Mac, открытая страница) будит её сразу.
public final class AttachmentSyncWork: SyncFileWork, @unchecked Sendable {
    public let transfer: AttachmentTransfer
    let attachments: AttachmentStore
    let collector: AttachmentCollector
    let transport: any SyncFileTransport
    private let lock = NSLock()
    private var wakeSleeper: (() -> Void)?
    private var lastCollection: Date?

    public init(attachments: AttachmentStore, transport: any SyncFileTransport, cipher: FileCipher) {
        self.attachments = attachments
        self.transport = transport
        transfer = AttachmentTransfer(attachments: attachments, transport: transport, cipher: cipher)
        collector = AttachmentCollector(attachments: attachments)
    }

    public func hasPendingWork() -> Bool {
        if (try? attachments.hasPendingTransfers()) == true { return true }
        return isCollectionDue && (try? collector.hasDue()) == true
    }

    /// Открытая страница: её файлы — первыми.
    public func prioritize(pageId: UUID) {
        guard let ids = try? attachments.attachmentIds(onPage: pageId), !ids.isEmpty else { return }
        Task {
            await transfer.prioritize(ids)
            wake()
        }
    }

    /// Прервать паузу: появилась новая работа.
    public func wake() {
        let wake = lock.withLock { wakeSleeper }
        wake?()
    }

    public func run() async {
        while !Task.isCancelled {
            do {
                if isCollectionDue {
                    lock.withLock { lastCollection = Date() }
                    try await collector.collect(transport: transport)
                }
                guard let next = try await transfer.runDue() else { return }
                await sleep(until: next)
            } catch {
                // Нет связи или сервер не ответил: цикл синхронизации запустит очередь снова на следующем круге.
                return
            }
        }
    }

    /// Сборщик сирот — раз в сутки.
    private var isCollectionDue: Bool {
        lock.withLock { lastCollection.map { Date().timeIntervalSince($0) > 86_400 } ?? true }
    }

    private func sleep(until date: Date) async {
        let delay = max(0.5, date.timeIntervalSinceNow)
        let task = Task { try? await Task.sleep(for: .seconds(delay)) }
        lock.withLock { wakeSleeper = { task.cancel() } }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        lock.withLock { wakeSleeper = nil }
    }
}
