import Foundation
import Synchronization
import Testing
@testable import NotesCore
@testable import Sync

/// Клиент файлов сервера (contracts/sync-and-files-api.md, «Файлы на сервере») и запуск очереди файлов из цикла синхронизации.
@Suite("Файлы на сервере")
struct SyncFileTransportTests {
    @Test("HTTP-клиент файлов по контракту настоящего сервера из server/", .enabled(if: LocalNodeSyncServer.isAvailable))
    func httpClientSpeaksTheServerContract() async throws {
        let server = try await LocalNodeSyncServer.start()
        defer { server.stop() }
        let token = try await server.bootstrapToken(name: "Mac A")
        let files = HTTPSyncServer(url: server.serverURL).fileTransport(deviceToken: token)
        let fileId = UUID()

        #expect(try await files.fileStatus(fileId) == nil)
        try await files.putFilePart(fileId, index: 1, count: 2, data: Data("вторая".utf8))
        // Повтор той же части — безопасен.
        try await files.putFilePart(fileId, index: 1, count: 2, data: Data("вторая".utf8))
        await #expect(throws: SyncServerError.fileIncomplete) { _ = try await files.filePart(fileId, index: 1) }
        let partial = try #require(try await files.fileStatus(fileId))
        #expect(partial.parts == [1])
        #expect(!partial.complete)
        await #expect(throws: SyncServerError.self) { try await files.completeFile(fileId, partCount: 2) }

        try await files.putFilePart(fileId, index: 0, count: 2, data: Data("первая".utf8))
        try await files.completeFile(fileId, partCount: 2)
        #expect(try await files.fileStatus(fileId)?.complete == true)
        #expect(try await files.filePart(fileId, index: 0) == Data("первая".utf8))
        await #expect(throws: SyncServerError.fileComplete) {
            try await files.putFilePart(fileId, index: 0, count: 2, data: Data("иначе".utf8))
        }
        let usage = try await files.filesUsage()
        #expect(usage.files == 1)
        #expect(usage.usedBytes == Data("первая".utf8).count + Data("вторая".utf8).count)

        try await files.deleteFile(fileId)
        try await files.deleteFile(fileId)
        #expect(try await files.fileStatus(fileId) == nil)
        await #expect(throws: SyncServerError.notFound) { _ = try await files.filePart(fileId, index: 0) }
    }

    @Test("Ошибки файлов понятны Юрию")
    func fileErrorsReadWell() {
        #expect(SyncServerError.storageFull.localizedDescription == "Кончилось место для файлов, общих для ваших Mac — новые файлы пока ждут на этом Mac")
        #expect(SyncServerError.fileIncomplete.localizedDescription == "Ждёт отправки с другого Mac")
    }

    @MainActor
    @Test("Цикл синхронизации запускает очередь файлов, только когда в ней что-то есть, и не ждёт её")
    func engineStartsFileWorkOnlyWhenQueueIsNotEmpty() async throws {
        let server = FakeTestServer()
        let mac = try EngineTestMac(name: "Mac A", wallMillis: 1_000)
        try await mac.connectFirst(server)
        let work = StubFileWork()
        mac.engine.fileWork = work
        mac.start()
        defer { mac.stop() }

        try await waitUntil { mac.engine.status == .ready }
        #expect(work.runs == 0)
        #expect(work.checks > 0)

        work.pending = true
        mac.engine.syncNow()
        try await waitUntil { work.runs == 1 }
        // Пока файл идёт, пачки уходят: правка доходит до сервера, не дожидаясь файла.
        _ = try mac.store.write { try $0.createPage(title: "Пока качается файл") }
        try await waitUntil { mac.engine.status == .ready && (try? Outbox(store: mac.store).pendingEntries().isEmpty) == true }
        #expect(work.isRunning)
        work.finish()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class StubFileWork: SyncFileWork, @unchecked Sendable {
    var pending = false
    private(set) var checks = 0
    private(set) var runs = 0
    private(set) var isRunning = false
    private var release: CheckedContinuation<Void, Never>?

    nonisolated func hasPendingWork() -> Bool {
        MainActor.assumeIsolated {
            checks += 1
            return pending
        }
    }

    nonisolated func run() async {
        await MainActor.run {
            runs += 1
            isRunning = true
        }
        await withCheckedContinuation { continuation in
            Task { @MainActor in self.release = continuation }
        }
        await MainActor.run { isRunning = false }
    }

    func finish() {
        release?.resume()
        release = nil
    }
}
