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
        return try importCopy(name: name, contentType: contentType) { destination in
            try Self.copy(source, to: destination)
        }
    }

    /// Записать содержимое из буфера (картинка — PNG) как файл.
    public func importData(_ data: Data, name: String, contentType: String) throws -> AttachmentRef {
        guard data.count <= AttachmentRef.maximumByteCount else { throw AttachmentError.tooLarge(name: name) }
        return try importCopy(name: name, contentType: contentType) { destination in
            try data.write(to: destination)
            return (data.count, Self.hex(SHA256.hash(data: data)))
        }
    }

    private func importCopy(name: String, contentType: String, write: (URL) throws -> (byteCount: Int, sha256: String)) throws -> AttachmentRef {
        let id = UUID.timeOrdered()
        let directory = folder.appendingPathComponent(id.attachmentKey, isDirectory: true)
        let fileName = Self.safeFileName(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (byteCount, sha256) = try write(directory.appendingPathComponent(fileName))
            guard byteCount <= AttachmentRef.maximumByteCount else { throw AttachmentError.tooLarge(name: name) }
            let ref = AttachmentRef(id: id, name: fileName, byteCount: byteCount, contentType: contentType, sha256: sha256)
            let record = AttachmentRecord(ref: ref, localPath: "\(id.attachmentKey)/\(fileName)", state: .local, orphanedAt: now())
            try store.database.dbWriter.write { db in try record.save(in: db) }
            return ref
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if let error = error as? AttachmentError { throw error }
            throw AttachmentError.cannotRead(error.localizedDescription)
        }
    }

    /// Копия кусками по 1 МБ с подсчётом SHA-256: 100 МБ не читаются в память целиком.
    private static func copy(_ source: URL, to destination: URL) throws -> (Int, String) {
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
        }
        return (byteCount, hex(hasher.finalize()))
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

    /// Файлы блоков страницы — открытая страница поднимает их в начало очереди скачивания (FR-120).
    public func attachmentIds(onPage pageId: UUID) throws -> [UUID] {
        let kinds = BlockKind.withAttachments.map(\.rawValue)
        let props = try store.database.dbWriter.read { db in
            try String.fetchAll(db, sql: """
                SELECT props FROM block WHERE pageId = ? AND isDeleted = 0 AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))
                ORDER BY sortKey
                """, arguments: StatementArguments([pageId.uuidString.lowercased()] + kinds))
        }
        return props.flatMap { text in
            ((try? JSONDecoder().decode(BlockProps.self, from: Data(text.utf8)))?.attachmentRefs ?? []).map(\.id)
        }
    }

    /// Есть ли что отправить или скачать: живой блок ссылается, а файл ещё не на сервере или не здесь.
    public func hasPendingTransfers() throws -> Bool {
        try store.database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM attachment WHERE orphanedAt IS NULL
                               AND state IN ('local', 'uploading', 'remote', 'downloading'))
                """) ?? false
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
