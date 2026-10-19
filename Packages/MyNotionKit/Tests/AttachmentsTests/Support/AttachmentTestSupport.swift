import CryptoKit
import Foundation
import Synchronization
@testable import Attachments
@testable import NotesCore
@testable import Sync

/// Пустая папка на время теста; стирается вместе с объектом.
final class TemporaryFolder: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotionAttachmentsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Файл с заданным содержимым в папке теста.
    func file(_ name: String, _ data: Data) throws -> URL {
        let url = url.appendingPathComponent("Оригиналы", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// Файл заданного размера без чтения в память (разреженный).
    func sparseFile(_ name: String, byteCount: Int) throws -> URL {
        let url = url.appendingPathComponent("Оригиналы", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.close()
        return url
    }
}

/// Время под управлением теста.
final class ManualNow: Sendable {
    private let current: Mutex<Date>

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(date)
    }

    var date: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var reading: @Sendable () -> Date { { [self] in date } }
}

/// Один Mac для тестов вложений: база, папка копий, хранилище.
struct AttachmentTestMac {
    let folder: TemporaryFolder
    let store: NotesStore
    let attachments: AttachmentStore
    let now: ManualNow
    let pageId: UUID

    init(now: ManualNow = ManualNow(), deviceId: UUID = UUID()) throws {
        folder = try TemporaryFolder()
        self.now = now
        let database = try AppDatabase.open(at: folder.url.appendingPathComponent("MyNotion.sqlite"))
        store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: deviceId))
        attachments = AttachmentStore(store: store, folder: folder.url.appendingPathComponent("Attachments", isDirectory: true),
                                      now: now.reading)
        store.addWriteHook(AttachmentReferenceCounter(now: now.reading))
        pageId = try store.write { try $0.createPage(title: "Страница").id }
    }

    /// Блок с файлом в конце страницы.
    @discardableResult
    func insertBlock(_ kind: BlockKind = .file, attachment ref: AttachmentRef, pageId: UUID? = nil, id: UUID = .timeOrdered()) throws -> Block {
        var props = BlockProps()
        props.attachment = ref
        let pageId = pageId ?? self.pageId
        return try store.write { transaction in
            let last = try transaction.blocks(ofPage: pageId).map(\.sortKey).max()
            return try transaction.insertBlock(Block(id: id, pageId: pageId, kind: kind, sortKey: .between(last, nil), props: props))
        }
    }

    func record(_ id: UUID) throws -> AttachmentRecord? {
        try attachments.record(id)
    }
}

/// Сервер файлов в памяти — строго по contracts/sync-and-files-api.md, «Файлы на сервере»: части, `complete`,
/// `409 file_incomplete` до сборки, `409 file_complete` после, корзина, квота `507`.
actor FakeFileServer {
    struct StoredFile {
        var partCount: Int
        var parts: [Int: Data] = [:]
        var complete = false
        var deleted = false
    }

    private(set) var files: [UUID: StoredFile] = [:]
    /// Все запросы по порядку: «PUT id 0», «GET id 1», «STATUS id», «COMPLETE id», «DELETE id».
    private(set) var log: [String] = []
    var limitBytes = Int.max
    /// Падать связью на этом запросе (один раз): например «PUT <id> 1».
    var failOnce: Set<String> = []

    func setLimit(_ bytes: Int) { limitBytes = bytes }
    func failNext(_ request: String) { failOnce.insert(request) }

    func store(_ id: UUID, partCount: Int, parts: [Int: Data], complete: Bool) {
        files[id] = StoredFile(partCount: partCount, parts: parts, complete: complete)
    }

    func file(_ id: UUID) -> StoredFile? { files[id] }

    func clearLog() { log.removeAll() }

    private var usedBytes: Int {
        files.values.filter { !$0.deleted }.flatMap(\.parts.values).reduce(0) { $0 + $1.count }
    }

    private func record(_ request: String) throws {
        log.append(request)
        if failOnce.remove(request) != nil { throw URLError(.networkConnectionLost) }
    }

    fileprivate func status(_ id: UUID) throws -> SyncFileStatus? {
        try record("STATUS \(id)")
        guard let file = files[id], !file.deleted else { return nil }
        return SyncFileStatus(fileId: id.uuidString.lowercased(), partCount: file.partCount, parts: file.parts.keys.sorted(),
                              complete: file.complete, bytes: file.parts.values.reduce(0) { $0 + $1.count })
    }

    fileprivate func put(_ id: UUID, index: Int, count: Int, data: Data) throws {
        try record("PUT \(id) \(index)")
        guard data.count <= AttachmentRef.partSize + 28 else { throw SyncServerError.tooLarge }
        guard index < count else { throw SyncServerError.badRequest("index") }
        var file = files[id] ?? StoredFile(partCount: count)
        if file.deleted { file = StoredFile(partCount: count) }
        guard file.partCount == count else { throw SyncServerError.badRequest("count") }
        guard !file.complete else { throw SyncServerError.fileComplete }
        guard usedBytes + data.count <= limitBytes else { throw SyncServerError.storageFull }
        file.parts[index] = data
        files[id] = file
    }

    fileprivate func complete(_ id: UUID, partCount: Int) throws {
        try record("COMPLETE \(id)")
        guard var file = files[id], !file.deleted else { throw SyncServerError.notFound }
        guard (0..<partCount).allSatisfy({ file.parts[$0] != nil }) else { throw SyncServerError.badRequest("missing") }
        file.complete = true
        files[id] = file
    }

    fileprivate func part(_ id: UUID, index: Int) throws -> Data {
        try record("GET \(id) \(index)")
        guard let file = files[id], !file.deleted else { throw SyncServerError.notFound }
        guard file.complete else { throw SyncServerError.fileIncomplete }
        guard let data = file.parts[index] else { throw SyncServerError.notFound }
        return data
    }

    fileprivate func delete(_ id: UUID) throws {
        try record("DELETE \(id)")
        files[id]?.deleted = true
    }

    fileprivate func usage() throws -> SyncFilesUsage {
        try record("USAGE")
        return SyncFilesUsage(usedBytes: usedBytes, limitBytes: limitBytes == .max ? 50 << 30 : limitBytes,
                              files: files.values.filter { !$0.deleted }.count)
    }

    nonisolated var transport: any SyncFileTransport { FakeFileTransport(server: self) }
}

private struct FakeFileTransport: SyncFileTransport {
    let server: FakeFileServer

    func fileStatus(_ fileId: UUID) async throws -> SyncFileStatus? { try await server.status(fileId) }
    func putFilePart(_ fileId: UUID, index: Int, count: Int, data: Data) async throws {
        try await server.put(fileId, index: index, count: count, data: data)
    }
    func completeFile(_ fileId: UUID, partCount: Int) async throws { try await server.complete(fileId, partCount: partCount) }
    func filePart(_ fileId: UUID, index: Int) async throws -> Data { try await server.part(fileId, index: index) }
    func deleteFile(_ fileId: UUID) async throws { try await server.delete(fileId) }
    func filesUsage() async throws -> SyncFilesUsage { try await server.usage() }
}

/// Случайные байты заданной длины (воспроизводимые).
func sampleBytes(_ count: Int, seed: UInt8 = 7) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    var value = seed
    for index in 0..<count {
        value = value &* 31 &+ 17
        bytes[index] = value ^ UInt8(truncatingIfNeeded: index >> 8)
    }
    return Data(bytes)
}

let testSyncKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))
