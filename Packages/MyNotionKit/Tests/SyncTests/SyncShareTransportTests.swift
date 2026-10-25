import Foundation
import Testing
@testable import Sync

/// Клиент ссылок (contracts/share-api.md) против настоящего сервера из server/.
@Suite("Ссылки на сервере")
struct SyncShareTransportTests {
    @Test("Включить, положить снимок и файл, открыть без входа, сменить ссылку, выключить", .enabled(if: LocalNodeSyncServer.isAvailable))
    func httpClientSpeaksTheShareContract() async throws {
        let server = try await LocalNodeSyncServer.start()
        defer { server.stop() }
        let token = try await server.bootstrapToken(name: "Mac A")
        let shares = HTTPSyncServer(url: server.serverURL).shareTransport(deviceToken: token)
        let pageId = UUID()
        let fileId = UUID()
        let key = pageId.uuidString.lowercased()
        let document = Data("""
        {"files":[{"byteCount":4,"id":"\(fileId.uuidString.lowercased())","mimeType":"image/png","name":"Картинка.png"}],\
        "pages":[{"blocks":[{"id":"\(UUID().uuidString.lowercased())","indent":0,"kind":"paragraph",\
        "text":{"runs":[],"string":"Привет по ссылке"}}],"id":"\(key)","title":"Опубликованная"}],\
        "rootPageId":"\(key)","version":1}
        """.utf8)
        let digest = String(repeating: "a", count: 64)

        let first = try await shares.setShare(pageId, enabled: true, includeSubpages: false)
        #expect(first.enabled)
        #expect(!first.includeSubpages)
        #expect(first.token.count == 43)
        #expect(try await shares.publishShare(pageId, digest: digest, document: document) == [fileId])

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("PNG!".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await shares.putShareFile(pageId, fileId: fileId, contentsOf: file)
        #expect(try await shares.publishShare(pageId, digest: digest, document: document).isEmpty)
        #expect(try await shares.shares().first?.digest == digest)

        let (page, response) = try await URLSession.shared.data(from: first.url(on: server.serverURL))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("Привет по ссылке"))

        let rotated = try await shares.rotateShare(pageId)
        #expect(rotated.token != first.token)
        #expect(try await status(of: first.url(on: server.serverURL)) == 404)
        #expect(try await status(of: rotated.url(on: server.serverURL)) == 200)

        let off = try await shares.setShare(pageId, enabled: false, includeSubpages: nil)
        #expect(!off.enabled)
        #expect(off.token == rotated.token)
        #expect(try await status(of: rotated.url(on: server.serverURL)) == 404)
        await #expect(throws: SyncServerError.shareDisabled) {
            _ = try await shares.publishShare(pageId, digest: digest, document: document)
        }
        try await shares.deleteShare(pageId)
        #expect(try await shares.shares().isEmpty)
    }

    private func status(of url: URL) async throws -> Int? {
        let (_, response) = try await URLSession.shared.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode
    }
}
