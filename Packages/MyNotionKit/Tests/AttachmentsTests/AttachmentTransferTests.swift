import Foundation
import Testing
@testable import Attachments
@testable import NotesCore
@testable import Sync

/// Отправка и докачка файлов через сервер (research R10, contracts/sync-and-files-api.md «Поведение Mac»).
/// Сеть — сервер файлов в памяти, время — часы теста.
@Suite struct AttachmentTransferTests {
    /// Две полные части по 8 МБ и хвост.
    static let bigSize = 2 * AttachmentRef.partSize + 1_234

    private func transfer(_ mac: AttachmentTestMac, _ server: FakeFileServer) -> AttachmentTransfer {
        AttachmentTransfer(attachments: mac.attachments, transport: server.transport, cipher: FileCipher(syncKey: testSyncKey),
                           now: mac.now.reading)
    }

    /// Mac с файлом в блоке, ещё не отправленным.
    private func macWithFile(size: Int = bigSize, name: String = "видео.mov", seed: UInt8 = 9) throws -> (AttachmentTestMac, AttachmentRef, Data) {
        let mac = try AttachmentTestMac()
        let bytes = sampleBytes(size, seed: seed)
        let ref = try mac.attachments.importFile(at: try mac.folder.file(name, bytes))
        try mac.insertBlock(attachment: ref)
        return (mac, ref, bytes)
    }

    // MARK: Отправка

    @Test func uploadSendsPartsOneByOneThenCompletes() async throws {
        let (mac, ref, bytes) = try macWithFile()
        let server = FakeFileServer()
        #expect(try mac.attachments.hasPendingTransfers())

        let next = try await transfer(mac, server).runDue()

        #expect(next == nil)
        #expect(await server.log == ["STATUS \(ref.id)", "PUT \(ref.id) 0", "PUT \(ref.id) 1", "PUT \(ref.id) 2", "COMPLETE \(ref.id)"])
        let stored = try #require(await server.file(ref.id))
        #expect(stored.complete)
        let cipher = FileCipher(syncKey: testSyncKey)
        let opened = try (0..<3).map { try cipher.open(stored.parts[$0]!, fileId: ref.id, index: $0, count: 3) }
        #expect(opened.reduce(Data(), +) == bytes)
        #expect(try mac.record(ref.id)?.state == .uploaded)
        #expect(try !mac.attachments.hasPendingTransfers())
    }

    @Test func interruptedUploadResumesFromFirstMissingPart() async throws {
        let (mac, ref, _) = try macWithFile()
        let server = FakeFileServer()
        await server.failNext("PUT \(ref.id) 1")
        let transfer = transfer(mac, server)

        await #expect(throws: URLError.self) { try await transfer.runDue() }
        let record = try #require(try mac.record(ref.id))
        #expect(record.state == .uploading)
        #expect(record.uploadedParts == [0])

        await server.clearLog()
        _ = try await transfer.runDue()
        #expect(await server.log == ["STATUS \(ref.id)", "PUT \(ref.id) 1", "PUT \(ref.id) 2", "COMPLETE \(ref.id)"])
        #expect(try mac.record(ref.id)?.state == .uploaded)
    }

    @Test func orphanedCopyIsNotUploaded() async throws {
        let mac = try AttachmentTestMac()
        _ = try mac.attachments.importFile(at: try mac.folder.file("ничей.txt", sampleBytes(10)))
        #expect(try !mac.attachments.hasPendingTransfers())
        let server = FakeFileServer()
        _ = try await transfer(mac, server).runDue()
        #expect(await server.log.isEmpty)
    }

    @Test func blockBatchDoesNotWaitForTheFile() throws {
        let mac = try AttachmentTestMac()
        Outbox.install(on: mac.store)
        try SyncSetup.enable(store: mac.store, account: SyncAccount(serverURL: URL(string: "https://example.com")!, deviceId: "mac-a",
                                                                     deviceName: "Mac A"))
        let ref = try mac.attachments.importFile(at: try mac.folder.file("a.png", sampleBytes(100)))

        let block = try mac.insertBlock(.image, attachment: ref)

        let entries = try Outbox(store: mac.store).pendingEntries()
        let carriesBlock = entries.flatMap(\.changes).contains { $0.entity == .block && $0.id == block.id }
        #expect(carriesBlock)
        #expect(try mac.record(ref.id)?.state == .local)
    }

    @Test func fullServerShowsMessageKeepsFileAndRetriesHourly() async throws {
        let (mac, ref, bytes) = try macWithFile(size: 2_000)
        let server = FakeFileServer()
        await server.setLimit(100)
        let transfer = transfer(mac, server)

        let next = try await transfer.runDue()

        #expect(await transfer.notice == "Кончилось место для файлов, общих для ваших Mac — новые файлы пока ждут на этом Mac")
        #expect(next == mac.now.date.addingTimeInterval(3_600))
        #expect(try Data(contentsOf: try #require(mac.attachments.fileURL(for: ref.id))) == bytes)
        #expect(try mac.record(ref.id)?.state != .uploaded)

        await server.clearLog()
        mac.now.advance(by: 600)
        _ = try await transfer.runDue()
        #expect(await server.log.isEmpty)

        await server.setLimit(.max)
        mac.now.advance(by: 3_000)
        #expect(try await transfer.runDue() == nil)
        #expect(try mac.record(ref.id)?.state == .uploaded)
        #expect(await transfer.notice == nil)
    }

    @Test func failingFileDoesNotStopOtherUploadsAndRetriesWithGrowingPauses() async throws {
        let mac = try AttachmentTestMac()
        let broken = try mac.attachments.importFile(at: try mac.folder.file("пропал.txt", sampleBytes(100, seed: 1)))
        let fine = try mac.attachments.importFile(at: try mac.folder.file("цел.txt", sampleBytes(100, seed: 2)))
        try mac.insertBlock(attachment: broken)
        try mac.insertBlock(attachment: fine)
        // Копию первого стёрли из папки — прочитать её нельзя.
        try FileManager.default.removeItem(at: try #require(mac.attachments.fileURL(for: broken.id)))
        let server = FakeFileServer()
        let transfer = transfer(mac, server)

        let next = try #require(try await transfer.runDue())

        #expect(try mac.record(fine.id)?.state == .uploaded)
        #expect(try mac.record(broken.id)?.state == .failed)
        #expect(next == mac.now.date.addingTimeInterval(60))
        // До срока — не трогается.
        await server.clearLog()
        mac.now.advance(by: 30)
        #expect(try await transfer.runDue() == next)
        #expect(await server.log.isEmpty)
        // Повтор по сроку, пауза растёт.
        mac.now.advance(by: 30)
        let second = try #require(try await transfer.runDue())
        #expect(second == mac.now.date.addingTimeInterval(120))
        #expect(await server.log == ["STATUS \(broken.id)"])

        // Копия вернулась — следующий повтор отправляет файл.
        try sampleBytes(100, seed: 1).write(to: mac.attachments.folder.appendingPathComponent(try #require(mac.record(broken.id)?.localPath)))
        mac.now.advance(by: 120)
        #expect(try await transfer.runDue() == nil)
        #expect(try mac.record(broken.id)?.state == .uploaded)
        #expect(try mac.record(broken.id)?.lastError == nil)
    }

    @Test func recordWithoutCopyIsNotRetriedInALoop() async throws {
        let mac = try AttachmentTestMac()
        let ref = try mac.attachments.importFile(at: try mac.folder.file("a.txt", sampleBytes(10)))
        try mac.insertBlock(attachment: ref)
        try mac.attachments.update(ref.id) { $0.localPath = nil }
        let server = FakeFileServer()

        #expect(try await transfer(mac, server).runDue() == nil)
        #expect(try mac.record(ref.id)?.state == .failed)
        #expect(try !mac.attachments.hasPendingTransfers())
        #expect(await server.log.isEmpty)
    }

    @Test func failingDownloadDoesNotStopOtherDownloads() async throws {
        let server = FakeFileServer()
        let (first, refA, _) = try macWithFile(size: 300, name: "a.bin", seed: 1)
        let refB = try first.attachments.importFile(at: try first.folder.file("b.bin", sampleBytes(300, seed: 2)))
        try first.insertBlock(attachment: refB)
        _ = try await transfer(first, server).runDue()
        let second = try receivingMac([(refA, nil), (refB, nil)])
        // Папка копий второго Mac не даёт создать каталог первого файла.
        try FileManager.default.createDirectory(at: second.attachments.folder, withIntermediateDirectories: true)
        try Data().write(to: second.attachments.folder.appendingPathComponent(refA.id.uuidString.lowercased()))

        let next = try #require(try await transfer(second, server).runDue())

        #expect(second.attachments.fileURL(for: refB.id) != nil)
        #expect(try second.record(refA.id)?.state == .failed)
        #expect(next == second.now.date.addingTimeInterval(60))
    }

    // MARK: Скачивание

    /// Второй Mac, к которому пришли блоки с файлами первого.
    private func receivingMac(_ refs: [(AttachmentRef, UUID?)]) throws -> AttachmentTestMac {
        let mac = try AttachmentTestMac()
        for (ref, pageId) in refs { try mac.insertBlock(attachment: ref, pageId: pageId) }
        return mac
    }

    @Test func secondMacDownloadsFilesOneByOneOpenPageFirst() async throws {
        let server = FakeFileServer()
        let (first, refA, bytesA) = try macWithFile(size: AttachmentRef.partSize + 10, name: "a.bin", seed: 1)
        let refB = try first.attachments.importFile(at: try first.folder.file("b.bin", sampleBytes(AttachmentRef.partSize + 20, seed: 2)))
        try first.insertBlock(attachment: refB)
        _ = try await transfer(first, server).runDue()

        let second = try AttachmentTestMac()
        let otherPage = try second.store.write { try $0.createPage(title: "Открытая").id }
        try second.insertBlock(attachment: refA)
        try second.insertBlock(attachment: refB, pageId: otherPage)
        #expect(try second.record(refA.id)?.state == .remote)
        #expect(try second.attachments.hasPendingTransfers())
        await server.clearLog()

        let transfer = transfer(second, server)
        await transfer.prioritize(try second.attachments.attachmentIds(onPage: otherPage))
        #expect(try await transfer.runDue() == nil)

        #expect(await server.log == ["GET \(refB.id) 0", "GET \(refB.id) 1", "GET \(refA.id) 0", "GET \(refA.id) 1"])
        #expect(try Data(contentsOf: try #require(second.attachments.fileURL(for: refA.id))) == bytesA)
        #expect(second.attachments.fileURL(for: refB.id)?.lastPathComponent == "b.bin")
        #expect(try second.record(refA.id)?.state == .uploaded)
        #expect(try !second.attachments.hasPendingTransfers())
    }

    @Test func fileNotYetSentWaitsWithGrowingPauses() async throws {
        let (first, ref, bytes) = try macWithFile(size: 3_000)
        let server = FakeFileServer()
        let second = try receivingMac([(ref, nil)])
        let transfer = transfer(second, server)
        var expectedMinutes: [Double] = []
        var observedMinutes: [Double] = []

        for minutes in [1.0, 2, 4, 8, 16, 32, 60, 60] {
            let started = second.now.date
            let next = try #require(try await transfer.runDue())
            observedMinutes.append(next.timeIntervalSince(started) / 60)
            expectedMinutes.append(minutes)
            #expect(try second.record(ref.id)?.lastError == AttachmentTransfer.waitingForOtherMac)
            // До срока сеть не трогается.
            await server.clearLog()
            second.now.advance(by: next.timeIntervalSince(started) - 1)
            _ = try await transfer.runDue()
            #expect(await server.log.isEmpty)
            second.now.advance(by: 1)
        }
        #expect(observedMinutes == expectedMinutes)

        // Отправитель закончил наполовину — 409 file_incomplete, всё ещё ждём.
        await server.store(ref.id, partCount: 1, parts: [:], complete: false)
        _ = try await transfer.runDue()
        #expect(try second.record(ref.id)?.state == .remote)

        _ = try await self.transfer(first, server).runDue()
        second.now.advance(by: 3_600)
        #expect(try await transfer.runDue() == nil)
        #expect(try Data(contentsOf: try #require(second.attachments.fileURL(for: ref.id))) == bytes)
        #expect(try second.record(ref.id)?.lastError == nil)
    }

    @Test func interruptedDownloadResumesFromMissingPart() async throws {
        let (first, ref, bytes) = try macWithFile()
        let server = FakeFileServer()
        _ = try await transfer(first, server).runDue()
        let second = try receivingMac([(ref, nil)])
        await server.failNext("GET \(ref.id) 2")
        let transfer = transfer(second, server)

        await #expect(throws: URLError.self) { try await transfer.runDue() }
        #expect(try second.record(ref.id)?.downloadedParts == [0, 1])
        #expect(second.attachments.fileURL(for: ref.id) == nil)

        await server.clearLog()
        _ = try await transfer.runDue()
        #expect(await server.log == ["GET \(ref.id) 2"])
        #expect(try Data(contentsOf: try #require(second.attachments.fileURL(for: ref.id))) == bytes)
    }

    @Test func downloadWithWrongChecksumIsNotKept() async throws {
        let (first, ref, _) = try macWithFile(size: 500)
        let server = FakeFileServer()
        _ = try await transfer(first, server).runDue()
        var forged = ref
        forged.sha256 = String(repeating: "a", count: 64)
        let second = try receivingMac([(forged, nil)])

        _ = try await transfer(second, server).runDue()

        let record = try #require(try second.record(ref.id))
        #expect(record.state == .failed)
        #expect(second.attachments.fileURL(for: ref.id) == nil)
    }

    @Test func damagedDownloadRetriesWithTheCorrectedDescription() async throws {
        let (first, ref, bytes) = try macWithFile(size: 500)
        let server = FakeFileServer()
        _ = try await transfer(first, server).runDue()
        var forged = ref
        forged.sha256 = String(repeating: "a", count: 64)
        let second = try receivingMac([(forged, nil)])
        let transfer = transfer(second, server)
        let next = try #require(try await transfer.runDue())
        #expect(try second.record(ref.id)?.state == .failed)

        // Пришло верное описание: запись следует за ним, повтор по сроку скачивает файл.
        var block = try #require(try second.store.write { try $0.blocks(ofPage: second.pageId) }.first { $0.props.attachment?.id == ref.id })
        block.props.attachment = ref
        try second.store.write { _ = try $0.updateBlock(block) }
        second.now.advance(by: next.timeIntervalSince(second.now.date))
        #expect(try await transfer.runDue() == nil)
        #expect(try Data(contentsOf: try #require(second.attachments.fileURL(for: ref.id))) == bytes)
    }

    @Test func turningSyncOffLeavesFilesOnThisMac() throws {
        let (mac, ref, bytes) = try macWithFile(size: 100)
        try SyncSetup.enable(store: mac.store, account: SyncAccount(serverURL: URL(string: "https://example.com")!, deviceId: "mac-a",
                                                                     deviceName: "Mac A"))
        try SyncSetup.disable(store: mac.store, secrets: InMemorySyncSecrets())
        #expect(try Data(contentsOf: try #require(mac.attachments.fileURL(for: ref.id))) == bytes)
        #expect(try mac.record(ref.id) != nil)
    }

    @Test func serverUsageIsReported() async throws {
        let (mac, _, _) = try macWithFile(size: 1_000)
        let server = FakeFileServer()
        _ = try await transfer(mac, server).runDue()
        let usage = try await server.transport.filesUsage()
        #expect(usage.files == 1)
        #expect(usage.usedBytes == 1_000 + 28)
    }
}
