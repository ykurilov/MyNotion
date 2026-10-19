import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Attachments
@testable import NotesCore
@testable import Sync

/// Копии файлов на Mac и учёт ссылок (research R9–R10, data-model.md «Attachment»).
@Suite struct AttachmentStoreTests {
    @Test func importCopiesFileIntoAttachmentsFolderAndLeavesOriginal() throws {
        let mac = try AttachmentTestMac()
        let bytes = sampleBytes(70_000)
        let original = try mac.folder.file("Отчёт 2026.pdf", bytes)

        let ref = try mac.attachments.importFile(at: original)

        let copy = mac.attachments.folder.appendingPathComponent(ref.id.uuidString.lowercased()).appendingPathComponent("Отчёт 2026.pdf")
        #expect(try Data(contentsOf: copy) == bytes)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(ref.name == "Отчёт 2026.pdf")
        #expect(ref.byteCount == 70_000)
        #expect(ref.contentType == "com.adobe.pdf")
        #expect(ref.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(ref.partCount == 1)
        #expect(mac.attachments.fileURL(for: ref.id) == copy)
        let record = try #require(try mac.record(ref.id))
        #expect(record.state == .local)
        #expect(record.localPath == "\(ref.id.uuidString.lowercased())/Отчёт 2026.pdf")
    }

    @Test func copyOpensAfterOriginalIsDeletedInFinder() throws {
        let mac = try AttachmentTestMac()
        let bytes = sampleBytes(4_096)
        let original = try mac.folder.file("фото.png", bytes)
        let ref = try mac.attachments.importFile(at: original)

        try FileManager.default.removeItem(at: original)

        let copy = try #require(mac.attachments.fileURL(for: ref.id))
        #expect(try Data(contentsOf: copy) == bytes)
    }

    @Test func pastedImageDataIsStoredAsFile() throws {
        let mac = try AttachmentTestMac()
        let png = sampleBytes(1_000)
        let ref = try mac.attachments.importData(png, name: "Картинка.png", contentType: "public.png")
        #expect(ref.contentType == "public.png")
        #expect(try Data(contentsOf: try #require(mac.attachments.fileURL(for: ref.id))) == png)
    }

    @Test func fileOver100MegabytesIsRefusedAndNothingIsCreated() throws {
        let mac = try AttachmentTestMac()
        let huge = try mac.folder.sparseFile("фильм.mov", byteCount: AttachmentRef.maximumByteCount + 1)

        #expect(throws: AttachmentError.tooLarge(name: "фильм.mov")) { try mac.attachments.importFile(at: huge) }
        #expect(AttachmentError.tooLarge(name: "фильм.mov").errorDescription == "Файл больше 100 МБ — MyNotion такие не хранит")
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: mac.attachments.folder.path)) ?? []
        #expect(copies.isEmpty)
        #expect(try mac.attachments.allRecords().isEmpty)
    }

    @Test func exactly100MegabytesIsAccepted() throws {
        let mac = try AttachmentTestMac()
        let file = try mac.folder.sparseFile("ровно.bin", byteCount: AttachmentRef.maximumByteCount)
        let ref = try mac.attachments.importFile(at: file)
        #expect(ref.byteCount == AttachmentRef.maximumByteCount)
        #expect(ref.partCount == 13)
    }

    // MARK: Копирование с заглушкой

    @Test func reservedImportKeepsIdReportsProgressAndEndsLocal() throws {
        let mac = try AttachmentTestMac()
        let bytes = sampleBytes(3 * 1_048_576 + 100)
        let original = try mac.folder.file("видео.mov", bytes)

        let reserved = try mac.attachments.reserveFileImport(at: original)
        #expect(reserved.name == "видео.mov" && reserved.byteCount == bytes.count && reserved.contentType == "com.apple.quicktime-movie")
        #expect(mac.attachments.fileURL(for: reserved.id) == nil, "Пока копируется — файла нет")
        #expect(mac.attachments.availability(of: reserved.id) == .failed(AttachmentStore.copyingMessage))

        let fractions = Mutex<[Double]>([])
        let ref = try mac.attachments.importFile(at: original, into: reserved) { fraction in fractions.withLock { $0.append(fraction) } }
        #expect(ref.id == reserved.id)
        #expect(ref.sha256 == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let reported = fractions.withLock { $0 }
        #expect(reported.count >= 4 && reported == reported.sorted() && reported.last == 1, "\(reported)")
        #expect(try mac.record(ref.id)?.state == .local)
        #expect(try Data(contentsOf: try #require(mac.attachments.fileURL(for: ref.id))) == bytes)
    }

    @Test func blockSavedDuringCopyDoesNotQueueDownload() throws {
        let mac = try AttachmentTestMac()
        let original = try mac.folder.file("отчёт.pdf", sampleBytes(1_000))
        let reserved = try mac.attachments.reserveFileImport(at: original)

        try mac.insertBlock(attachment: reserved)
        #expect(try mac.record(reserved.id)?.state == .failed, "Не в очереди скачивания: файл копируется здесь")
        #expect(try !mac.attachments.hasPendingTransfers())

        _ = try mac.attachments.importFile(at: original, into: reserved) { _ in }
        #expect(try mac.record(reserved.id)?.state == .local)
        #expect(try mac.record(reserved.id)?.orphanedAt == nil, "Блок уже ссылается — не сирота")
    }

    @Test func copiedFileDescriptionReachesBlockWithoutOpenPage() throws {
        let mac = try AttachmentTestMac()
        let original = try mac.folder.file("отчёт.pdf", sampleBytes(1_000))
        let reserved = try mac.attachments.reserveFileImport(at: original)
        let block = try mac.insertBlock(attachment: reserved)
        var bookmark = BlockProps()
        bookmark.image = reserved
        let other = try mac.store.write { tx in
            try tx.insertBlock(Block(pageId: mac.pageId, kind: .bookmark, sortKey: .between(nil, nil), props: bookmark))
        }

        // Страницу закрыли посреди копирования: описание с SHA-256 ложится в блоки прямо в базе.
        let ref = try mac.attachments.importFile(at: original, into: reserved) { _ in }
        let pages = try mac.attachments.placeInBlocks(ref)

        #expect(pages == [mac.pageId])
        #expect(try mac.store.write { try $0.block(block.id) }?.props.attachment == ref)
        #expect(try mac.store.write { try $0.block(other.id) }?.props.image == ref)
        #expect(try mac.attachments.placeInBlocks(ref).isEmpty, "Повтор ничего не меняет")
    }

    @Test func reservingOver100MegabytesIsRefused() throws {
        let mac = try AttachmentTestMac()
        let huge = try mac.folder.sparseFile("фильм.mov", byteCount: AttachmentRef.maximumByteCount + 1)
        #expect(throws: AttachmentError.tooLarge(name: "фильм.mov")) { try mac.attachments.reserveFileImport(at: huge) }
        #expect(try mac.attachments.allRecords().isEmpty)
    }

    @Test func copyInterruptedByQuitIsReportedAfterRelaunch() throws {
        let mac = try AttachmentTestMac()
        let reserved = try mac.attachments.reserveFileImport(at: try mac.folder.file("а.txt", sampleBytes(10)))
        try FileManager.default.createDirectory(at: mac.attachments.folder.appendingPathComponent(reserved.id.uuidString.lowercased()),
                                                withIntermediateDirectories: true)

        try mac.attachments.abandonInterruptedCopies()

        #expect(mac.attachments.availability(of: reserved.id) == .failed(AttachmentStore.interruptedCopyMessage))
        #expect(!FileManager.default.fileExists(atPath: mac.attachments.folder.appendingPathComponent(reserved.id.uuidString.lowercased()).path))
    }

    @Test func remoteRecordFollowsBlockWhenItsDescriptionChanges() throws {
        let mac = try AttachmentTestMac()
        var ref = AttachmentRef(name: "с другого.pdf", byteCount: 100, contentType: "com.adobe.pdf", sha256: "")
        var block = try mac.insertBlock(attachment: ref)
        // Другой Mac докопировал файл и прислал описание с SHA-256 — запись очереди скачивания обновляется.
        ref.sha256 = String(repeating: "a", count: 64)
        block.props.attachment = ref
        try mac.store.write { _ = try $0.updateBlock(block) }
        #expect(try mac.record(ref.id)?.ref.sha256 == ref.sha256)
    }

    @Test func referencesAreRecountedInTheSameTransaction() throws {
        let mac = try AttachmentTestMac()
        let ref = try mac.attachments.importFile(at: try mac.folder.file("a.txt", sampleBytes(10)))
        // Пока ни один блок не ссылается — сирота с момента копирования.
        #expect(try mac.record(ref.id)?.orphanedAt == mac.now.date)

        let block = try mac.insertBlock(attachment: ref)
        #expect(try mac.record(ref.id)?.orphanedAt == nil)

        mac.now.advance(by: 60)
        try mac.store.write { try $0.deleteBlock(block.id) }
        #expect(try mac.record(ref.id)?.orphanedAt == mac.now.date)

        // ⌘Z: блок вернулся с той же ссылкой — пометка снята.
        try mac.insertBlock(attachment: ref, id: block.id)
        #expect(try mac.record(ref.id)?.orphanedAt == nil)
    }

    @Test func blockOfKindWithoutFilesDoesNotQueueDownload() throws {
        let mac = try AttachmentTestMac()
        let ref = AttachmentRef(name: "с другого.pdf", byteCount: 100, contentType: "com.adobe.pdf", sha256: String(repeating: "0", count: 64))
        // Абзац с оставшимся в props описанием файла: блок файла не показывает — как и в подсчёте сирот.
        try mac.insertBlock(.paragraph, attachment: ref)
        #expect(try mac.record(ref.id) == nil)
        #expect(try !mac.attachments.hasPendingTransfers())
    }

    @Test func returnedBlockSendsItsCopyAgainAfterServerErasedIt() async throws {
        let mac = try AttachmentTestMac()
        let server = FakeFileServer()
        let ref = try mac.attachments.importFile(at: try mac.folder.file("a.txt", sampleBytes(10)))
        let block = try mac.insertBlock(attachment: ref)
        let transfer = AttachmentTransfer(attachments: mac.attachments, transport: server.transport,
                                          cipher: FileCipher(syncKey: testSyncKey), now: mac.now.reading)
        _ = try await transfer.runDue()
        try mac.store.write { try $0.deleteBlock(block.id) }
        // Сборщик другого Mac стёр файл на сервере (в корзину).
        try await server.transport.deleteFile(ref.id)

        // ⌘Z: блок вернулся — копия этого Mac уходит на сервер снова.
        try mac.insertBlock(attachment: ref, id: block.id)
        #expect(try mac.attachments.hasPendingTransfers())
        _ = try await transfer.runDue()
        let stored = try #require(await server.file(ref.id))
        #expect(!stored.deleted)
        #expect(stored.complete)
        #expect(try mac.record(ref.id)?.state == .uploaded)
    }

    @Test func replacingAttachmentOrphansTheOldOne() throws {
        let mac = try AttachmentTestMac()
        let first = try mac.attachments.importFile(at: try mac.folder.file("1.txt", sampleBytes(10, seed: 1)))
        let second = try mac.attachments.importFile(at: try mac.folder.file("2.txt", sampleBytes(10, seed: 2)))
        var block = try mac.insertBlock(attachment: first)

        block.props.attachment = second
        try mac.store.write { _ = try $0.updateBlock(block) }

        #expect(try mac.record(first.id)?.orphanedAt != nil)
        #expect(try mac.record(second.id)?.orphanedAt == nil)
    }

    @Test func blockWithUnknownFileFromAnotherMacQueuesDownload() throws {
        let mac = try AttachmentTestMac()
        let ref = AttachmentRef(name: "с другого.pdf", byteCount: 100, contentType: "com.adobe.pdf", sha256: String(repeating: "0", count: 64))

        try mac.insertBlock(attachment: ref)

        let record = try #require(try mac.record(ref.id))
        #expect(record.state == .remote)
        #expect(record.localPath == nil)
        #expect(record.orphanedAt == nil)
        #expect(mac.attachments.fileURL(for: ref.id) == nil)
    }

    @Test func bookmarkImageAndVideoPosterAreReferencesToo() throws {
        let mac = try AttachmentTestMac()
        let image = try mac.attachments.importData(sampleBytes(10, seed: 3), name: "og.png", contentType: "public.png")
        let poster = try mac.attachments.importData(sampleBytes(10, seed: 4), name: "poster.jpg", contentType: "public.jpeg")
        var bookmark = BlockProps()
        bookmark.url = URL(string: "https://example.com")
        bookmark.image = image
        var video = BlockProps()
        video.videoSource = .youtube
        video.poster = poster
        try mac.store.write { transaction in
            try transaction.insertBlock(Block(pageId: mac.pageId, kind: .bookmark, sortKey: .between(nil, nil), props: bookmark))
            try transaction.insertBlock(Block(pageId: mac.pageId, kind: .video, sortKey: .between(nil, nil), props: video))
        }
        #expect(try mac.record(image.id)?.orphanedAt == nil)
        #expect(try mac.record(poster.id)?.orphanedAt == nil)
    }

    @Test func erasesOnlyOrphansOlderThan30DaysThatAllDevicesKnowAbout() async throws {
        let mac = try AttachmentTestMac()
        mac.store.keepsDeletionMarks = true
        let server = FakeFileServer()
        let old = try mac.attachments.importFile(at: try mac.folder.file("старый.txt", sampleBytes(10, seed: 1)))
        let fresh = try mac.attachments.importFile(at: try mac.folder.file("свежий.txt", sampleBytes(10, seed: 2)))
        let oldBlock = try mac.insertBlock(attachment: old)
        try mac.store.write { try $0.deleteBlock(oldBlock.id) }
        mac.now.advance(by: 2 * 86_400)
        let freshBlock = try mac.insertBlock(attachment: fresh)
        try mac.store.write { try $0.deleteBlock(freshBlock.id) }
        mac.now.advance(by: 29 * 86_400)

        let collector = AttachmentCollector(attachments: mac.attachments, now: mac.now.reading)
        // Пометку удаления ещё не получили все устройства — стирать нельзя.
        #expect(try await collector.collect(transport: server.transport).isEmpty)
        #expect(mac.attachments.fileURL(for: old.id) != nil)

        try mac.store.write { try $0.eraseDeletionMarksAndTombstones() }
        let erased = try await collector.collect(transport: server.transport)

        #expect(erased == [old.id])
        #expect(mac.attachments.fileURL(for: old.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: mac.attachments.folder.appendingPathComponent(old.id.uuidString.lowercased()).path))
        #expect(try mac.record(old.id) == nil)
        #expect(await server.log == ["DELETE \(old.id)"])
        // Сирота моложе 30 дней остаётся.
        #expect(mac.attachments.fileURL(for: fresh.id) != nil)
    }

    @Test func erasingWithoutSyncOnlyRemovesLocalCopy() async throws {
        let mac = try AttachmentTestMac()
        let ref = try mac.attachments.importFile(at: try mac.folder.file("x.txt", sampleBytes(10)))
        mac.now.advance(by: 31 * 86_400)
        let erased = try await AttachmentCollector(attachments: mac.attachments, now: mac.now.reading).collect(transport: nil)
        #expect(erased == [ref.id])
        #expect(mac.attachments.fileURL(for: ref.id) == nil)
    }

    @Test func diskUsageCountsLocalCopies() throws {
        let mac = try AttachmentTestMac()
        _ = try mac.attachments.importFile(at: try mac.folder.file("a.bin", sampleBytes(1_000)))
        _ = try mac.attachments.importFile(at: try mac.folder.file("b.bin", sampleBytes(2_000)))
        let usage = try mac.attachments.localUsage()
        #expect(usage.files == 2)
        #expect(usage.bytes == 3_000)
    }
}
