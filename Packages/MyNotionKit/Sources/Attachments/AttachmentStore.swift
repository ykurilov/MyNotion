import CryptoKit
import Foundation
import GRDB
import NotesCore
import UniformTypeIdentifiers

/// Копии файлов на Mac (research R9): `Attachments/<id>/<имя>` — обычный файл в исходном виде, его можно открыть в Finder.
/// Вставка копирует файл (оригинал не трогается); описание — `AttachmentRef` в блоке, состояние копии — таблица `attachment`.
public final class AttachmentStore: Sendable {
    public let store: NotesStore
    /// Папка копий.
    public let folder: URL
    let now: @Sendable () -> Date

    public init(store: NotesStore, folder: URL = AttachmentStore.defaultFolder, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.folder = folder
        self.now = now
    }

    /// `~/Library/Application Support/MyNotion/Attachments/` — рядом с базой.
    public static var defaultFolder: URL {
        AppDatabase.defaultURL.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
    }

    /// Папка копий для базы по другому пути (тесты, служебные запуски).
    public static func folder(forDatabaseAt url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
    }

    // MARK: Вставка

    /// Скопировать файл в папку копий. Больше 100 МБ — `tooLarge`, ничего не создаётся. Копия — сирота,
    /// пока её не возьмёт блок (иначе брошенная вставка сотрётся через 30 дней).
    public func importFile(at source: URL) throws -> AttachmentRef {
        let name = source.lastPathComponent
        let byteCount: Int
        do {
            byteCount = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw AttachmentError.cannotRead(error.localizedDescription)
        }
        guard byteCount <= AttachmentRef.maximumByteCount else { throw AttachmentError.tooLarge(name: name) }
        let contentType = UTType(filenameExtension: source.pathExtension)?.identifier ?? UTType.data.identifier
        return try importCopy(name: name, contentType: contentType, origin: .outside) { destination in
            try Self.copy(source, to: destination)
        }
    }

    // MARK: Копирование с заглушкой

    /// Надпись на заглушке, пока файл копируется (вид редактора показывает поверх неё ход копирования).
    public static let copyingMessage = "Копируется…"
    /// Копирование прервал выход из приложения.
    public static let interruptedCopyMessage = "Копирование прервалось — вставьте файл ещё раз"

    /// Занять место под файл до копирования, чтобы блок со ссылкой на него появился сразу: описание без SHA-256
    /// и запись в состоянии `failed` с надписью `copyingMessage` — её не берут ни отправка, ни скачивание, а подсчёт
    /// ссылок не ставит её в очередь. Больше 100 МБ — `tooLarge`, ничего не создаётся.
    public func reserveFileImport(at source: URL) throws -> AttachmentRef {
        let name = source.lastPathComponent
        let byteCount: Int
        do {
            byteCount = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        } catch {
            throw AttachmentError.cannotRead(error.localizedDescription)
        }
        guard byteCount <= AttachmentRef.maximumByteCount else { throw AttachmentError.tooLarge(name: name) }
        let contentType = UTType(filenameExtension: source.pathExtension)?.identifier ?? UTType.data.identifier
        let ref = AttachmentRef(name: Self.safeFileName(name), byteCount: byteCount, contentType: contentType, sha256: "")
        var record = AttachmentRecord(ref: ref, localPath: nil, state: .failed, orphanedAt: now())
        record.lastError = Self.copyingMessage
        try store.database.dbWriter.write { db in try record.save(in: db) }
        return ref
    }

    /// Скопировать файл под занятым `reserved` id; `progress` — доля скопированного, от 0 до 1. Не вышло — запись
    /// остаётся `failed` с причиной, копии нет.
    public func importFile(at source: URL, into reserved: AttachmentRef, progress: @escaping @Sendable (Double) -> Void) throws -> AttachmentRef {
        do {
            return try importCopy(name: reserved.name, contentType: reserved.contentType, id: reserved.id,
                                  origin: .finder(source)) { destination in
                try Self.copy(source, to: destination, expectedByteCount: reserved.byteCount, progress: progress)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? update(reserved.id) { $0.lastError = message }
            throw error
        }
    }

    /// Копия готова: описание с SHA-256 — во все живые блоки, которые ссылаются на файл, прямо в базе, без шага ⌘Z.
    /// Страницу могли закрыть посреди копирования: иначе на другие Mac ушло бы описание без SHA-256, и скачивание там
    /// кончилось бы «повреждён». Возвращает страницы изменённых блоков — открытые документы примут записанное.
    @discardableResult
    public func placeInBlocks(_ ref: AttachmentRef) throws -> Set<UUID> {
        try store.write { transaction in
            let ids = try String.fetchAll(transaction.database, sql: """
                SELECT id FROM block WHERE isDeleted = 0 AND instr(upper(props), upper(?)) > 0
                """, arguments: [ref.id.attachmentKey]).compactMap(UUID.init(uuidString:))
            var pageIds: Set<UUID> = []
            for id in ids {
                guard var block = try transaction.block(id) else { continue }
                let before = block.props
                block.props.replaceAttachment(ref)
                guard block.props != before else { continue }
                try transaction.updateBlock(block)
                pageIds.insert(block.pageId)
            }
            return pageIds
        }
    }

    /// Занять место под картинку, которая скачается следом (вставка из Notion): как `reserveFileImport`, только
    /// размер и тип файла ещё не известны — тип по расширению имени, иначе картинка.
    public func reserveDownload(named name: String) throws -> AttachmentRef {
        let contentType = UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? UTType.image.identifier
        let ref = AttachmentRef(name: Self.safeFileName(name), byteCount: 0, contentType: contentType, sha256: "")
        var record = AttachmentRecord(ref: ref, localPath: nil, state: .failed, orphanedAt: now())
        record.lastError = Self.copyingMessage
        try store.database.dbWriter.write { db in try record.save(in: db) }
        return ref
    }

    /// Скачанное — под занятым `reserved` id. Не вышло — запись остаётся `failed` с причиной.
    public func importData(_ data: Data, into reserved: AttachmentRef, contentType: String) throws -> AttachmentRef {
        do {
            guard data.count <= AttachmentRef.maximumByteCount else { throw AttachmentError.tooLarge(name: reserved.name) }
            return try importCopy(name: reserved.name, contentType: contentType, id: reserved.id, origin: .outside) { destination in
                try data.write(to: destination)
                return (data.count, Self.hex(SHA256.hash(data: data)))
            }
        } catch {
            try? failReservation(reserved.id, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            throw error
        }
    }

    /// Причина, по которой файла под занятым местом не будет: её показывает заглушка блока.
    public func failReservation(_ id: UUID, message: String) throws {
        try update(id) { $0.lastError = message }
    }

    /// После запуска: копирования, прерванные выходом из приложения, — с понятной надписью, недописанные копии стёрты.
    public func abandonInterruptedCopies() throws {
        let interrupted = try allRecords().filter { $0.state == .failed && $0.lastError == Self.copyingMessage }
        for record in interrupted {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(record.id.attachmentKey, isDirectory: true))
            try update(record.id) { $0.lastError = Self.interruptedCopyMessage }
        }
    }

    /// Записать содержимое из буфера (картинка — PNG) как файл.
    public func importData(_ data: Data, name: String, contentType: String) throws -> AttachmentRef {
        guard data.count <= AttachmentRef.maximumByteCount else { throw AttachmentError.tooLarge(name: name) }
        return try importCopy(name: name, contentType: contentType, origin: .outside) { destination in
            try data.write(to: destination)
            return (data.count, Self.hex(SHA256.hash(data: data)))
        }
    }

    /// Откуда копия: файл Finder несёт пометку карантина исходника, всё остальное (сеть, буфер, импорт) — помечается.
    private enum CopyOrigin {
        case finder(URL)
        case outside
    }

    private func importCopy(name: String, contentType: String, id: UUID = .timeOrdered(), origin: CopyOrigin,
                            write: (URL) throws -> (byteCount: Int, sha256: String)) throws -> AttachmentRef {
        let directory = folder.appendingPathComponent(id.attachmentKey, isDirectory: true)
        let fileName = Self.safeFileName(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(fileName)
            let (byteCount, sha256) = try write(destination)
            switch origin {
            case .finder(let source): FileQuarantine.carryOver(from: source, to: destination)
            case .outside: FileQuarantine.mark(destination)
            }
            guard byteCount <= AttachmentRef.maximumByteCount else { throw AttachmentError.tooLarge(name: name) }
            let ref = AttachmentRef(id: id, name: fileName, byteCount: byteCount, contentType: contentType, sha256: sha256)
            try store.database.dbWriter.write { db in
                // Блок мог сослаться на занятый id, пока шло копирование: тогда файл уже не сирота.
                let referenced = try Bool.fetchOne(db, sql: "SELECT orphanedAt IS NULL FROM attachment WHERE id = ?",
                                                   arguments: [id.attachmentKey]) ?? false
                let record = AttachmentRecord(ref: ref, localPath: "\(id.attachmentKey)/\(fileName)", state: .local,
                                              orphanedAt: referenced ? nil : now())
                try record.save(in: db)
            }
            return ref
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if let error = error as? AttachmentError { throw error }
            throw AttachmentError.cannotRead(error.localizedDescription)
        }
    }

    /// Копия кусками по 1 МБ с подсчётом SHA-256: 100 МБ не читаются в память целиком.
    private static func copy(_ source: URL, to destination: URL, expectedByteCount: Int = 0,
                             progress: (@Sendable (Double) -> Void)? = nil) throws -> (Int, String) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = SHA256()
        var byteCount = 0
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            byteCount += chunk.count
            guard byteCount <= AttachmentRef.maximumByteCount else { throw AttachmentError.tooLarge(name: source.lastPathComponent) }
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
            progress?(min(1, Double(byteCount) / Double(max(expectedByteCount, 1))))
        }
        progress?(1)
        return (byteCount, hex(hasher.finalize()))
    }

    /// Положить копию под готовым описанием файла — для образцов галереи и «богатой» страницы замеров,
    /// где блоки ссылаются на файлы, которых на Mac ещё нет.
    public func adoptSampleCopy(_ data: Data, as ref: AttachmentRef) throws {
        let directory = folder.appendingPathComponent(ref.id.attachmentKey, isDirectory: true)
        let fileName = Self.safeFileName(ref.name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(fileName))
        var record = AttachmentRecord(ref: ref, localPath: "\(ref.id.attachmentKey)/\(fileName)", state: .uploaded, orphanedAt: nil)
        record.uploadedParts = Set(0..<ref.partCount)
        try store.database.dbWriter.write { db in try record.save(in: db) }
    }

    /// Образец заглушки «Ждёт отправки с другого Mac» для галереи.
    public func markWaitingForOtherMac(_ id: UUID) throws {
        try update(id) {
            $0.state = .remote
            $0.lastError = AttachmentTransfer.waitingForOtherMac
        }
    }

    // MARK: Чтение

    /// Копия на этом Mac; `nil` — файла здесь ещё нет.
    public func fileURL(for id: UUID) -> URL? {
        guard let localPath = try? store.database.dbWriter.read({ db in
            try String.fetchOne(db, sql: "SELECT localPath FROM attachment WHERE id = ?", arguments: [id.attachmentKey])
        }) else { return nil }
        let url = folder.appendingPathComponent(localPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Что показать вместо файла, пока его нет.
    public func availability(of id: UUID) -> AttachmentAvailability {
        if let url = fileURL(for: id) { return .ready(url) }
        guard let record = try? record(id) else { return .downloading }
        switch record.state {
        case .failed: return .failed(record.lastError ?? AttachmentError.damaged.localizedDescription)
        default: return record.lastError == AttachmentTransfer.waitingForOtherMac ? .waitingForOtherMac : .downloading
        }
    }

    public func record(_ id: UUID) throws -> AttachmentRecord? {
        try store.database.dbWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM attachment WHERE id = ?", arguments: [id.attachmentKey]).flatMap(AttachmentRecord.init(row:))
        }
    }

    public func allRecords() throws -> [AttachmentRecord] {
        try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM attachment ORDER BY id").compactMap(AttachmentRecord.init(row:))
        }
    }

    /// Файлы страницы — открытая страница поднимает их в начало очереди скачивания (FR-120): файл обложки (он вверху
    /// страницы), затем файлы блоков по порядку.
    public func attachmentIds(onPage pageId: UUID) throws -> [UUID] {
        let kinds = BlockKind.withAttachments.map(\.rawValue)
        let (cover, props) = try store.database.dbWriter.read { db in
            (try String.fetchOne(db, sql: "SELECT cover FROM page WHERE id = ?", arguments: [pageId.uuidString.lowercased()]),
             try String.fetchAll(db, sql: """
                SELECT props FROM block WHERE pageId = ? AND isDeleted = 0 AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))
                ORDER BY sortKey
                """, arguments: StatementArguments([pageId.uuidString.lowercased()] + kinds)))
        }
        let coverId = cover.flatMap { try? JSONDecoder().decode(PageCover.self, from: Data($0.utf8)) }?.attachment?.id
        return [coverId].compactMap { $0 } + props.flatMap { text in
            ((try? JSONDecoder().decode(BlockProps.self, from: Data(text.utf8)))?.attachmentRefs ?? []).map(\.id)
        }
    }

    /// Есть ли что отправить или скачать: живой блок ссылается, а файл ещё не на сервере или не здесь
    /// (в том числе ждёт повтора после сбоя).
    public func hasPendingTransfers() throws -> Bool {
        try store.database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM attachment WHERE orphanedAt IS NULL
                               AND (state IN ('local', 'uploading', 'remote', 'downloading')
                                    OR (state = 'failed' AND lastError IN (?, ?, ?))))
                """, arguments: [AttachmentTransfer.uploadFailedMessage, AttachmentTransfer.downloadFailedMessage,
                                 AttachmentError.damaged.localizedDescription]) ?? false
        }
    }

    /// Сколько места занимают копии на этом Mac — для «Настройки → Синхронизация».
    public func localUsage() throws -> (bytes: Int, files: Int) {
        let records = try allRecords().filter { $0.localPath != nil }
        return (records.reduce(0) { $0 + $1.ref.byteCount }, records.count)
    }

    // MARK: Запись состояния

    func update(_ id: UUID, _ change: (inout AttachmentRecord) -> Void) throws {
        try store.database.dbWriter.write { db in
            guard var record = try Row.fetchOne(db, sql: "SELECT * FROM attachment WHERE id = ?", arguments: [id.attachmentKey])
                .flatMap(AttachmentRecord.init(row:)) else { return }
            change(&record)
            try record.save(in: db)
        }
    }

    func records(sql: String, arguments: StatementArguments = []) throws -> [AttachmentRecord] {
        try store.database.dbWriter.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(AttachmentRecord.init(row:))
        }
    }

    func directory(for id: UUID) -> URL {
        folder.appendingPathComponent(id.attachmentKey, isDirectory: true)
    }

    /// Стереть копию, на которую никто не ссылается (откат команды, вложившей файл), — сразу, а не через 30 дней.
    /// Проверка ссылок и удаление строки — одной записью: ссылка, появившаяся рядом, копию сохраняет.
    public func discardIfUnreferenced(_ id: UUID) throws {
        let removed = try store.database.dbWriter.write { db -> Bool in
            try db.execute(sql: "DELETE FROM attachment WHERE id = ? AND NOT EXISTS (\(AttachmentReferenceCounter.liveReference))",
                           arguments: [id.attachmentKey])
            return db.changesCount > 0
        }
        if removed { try? FileManager.default.removeItem(at: directory(for: id)) }
    }

    /// Стереть копию и её строку.
    func erase(_ id: UUID) throws {
        try? FileManager.default.removeItem(at: directory(for: id))
        try store.database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM attachment WHERE id = ?", arguments: [id.attachmentKey])
        }
    }

    func postAvailabilityChange(_ id: UUID) {
        Task { @MainActor in NotificationCenter.default.post(name: AttachmentRef.availabilityDidChange, object: id) }
    }

    // MARK: Внутреннее

    /// Имя файла без знаков, которых не бывает в именах файлов macOS.
    static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "Файл" }
        return cleaned.hasPrefix(".") ? "_" + cleaned.dropFirst() : cleaned
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
