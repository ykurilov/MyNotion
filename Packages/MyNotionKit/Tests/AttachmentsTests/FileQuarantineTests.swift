import Foundation
import Testing
@testable import Attachments
@testable import NotesCore
@testable import Sync

/// Файлы, пришедшие извне (сеть, другой Mac, импорт), — с пометкой карантина macOS: открытие проходит проверку Gatekeeper.
@Suite struct FileQuarantineTests {
    private func isQuarantined(_ url: URL?) -> Bool {
        guard let url else { return false }
        return getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0
    }

    @Test func dataFromNetworkOrBufferIsQuarantined() throws {
        let mac = try AttachmentTestMac()
        let ref = try mac.attachments.importData(sampleBytes(10), name: "скачанный.sh", contentType: "public.shell-script")
        #expect(isQuarantined(mac.attachments.fileURL(for: ref.id)))
    }

    @Test func importedFileIsQuarantined() throws {
        let mac = try AttachmentTestMac()
        let ref = try mac.attachments.importFile(at: try mac.folder.file("из Notion.pdf", sampleBytes(10)))
        #expect(isQuarantined(mac.attachments.fileURL(for: ref.id)))
    }

    @Test func finderCopyKeepsQuarantineOfItsOriginal() throws {
        let mac = try AttachmentTestMac()
        let own = try mac.folder.file("свой.txt", sampleBytes(10, seed: 1))
        let downloaded = try mac.folder.file("из Safari.command", sampleBytes(10, seed: 2))
        FileQuarantine.mark(downloaded)
        #expect(isQuarantined(downloaded))

        let ownRef = try mac.attachments.importFile(at: own, into: mac.attachments.reserveFileImport(at: own)) { _ in }
        let downloadedRef = try mac.attachments.importFile(at: downloaded, into: mac.attachments.reserveFileImport(at: downloaded)) { _ in }

        #expect(!isQuarantined(mac.attachments.fileURL(for: ownRef.id)))
        #expect(isQuarantined(mac.attachments.fileURL(for: downloadedRef.id)))
    }

    @Test func fileFromAnotherMacIsQuarantined() async throws {
        let first = try AttachmentTestMac()
        let ref = try first.attachments.importFile(at: try first.folder.file("a.pkg", sampleBytes(100)))
        try first.insertBlock(attachment: ref)
        let server = FakeFileServer()
        let cipher = FileCipher(syncKey: testSyncKey)
        _ = try await AttachmentTransfer(attachments: first.attachments, transport: server.transport, cipher: cipher).runDue()
        let second = try AttachmentTestMac()
        try second.insertBlock(attachment: ref)

        _ = try await AttachmentTransfer(attachments: second.attachments, transport: server.transport, cipher: cipher).runDue()

        #expect(isQuarantined(second.attachments.fileURL(for: ref.id)))
    }
}
