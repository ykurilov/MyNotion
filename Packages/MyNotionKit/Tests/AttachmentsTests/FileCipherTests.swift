import CryptoKit
import Foundation
import Testing
@testable import Attachments
@testable import NotesCore

/// Шифрование частей файла (contracts/sync-and-files-api.md, «Шифрование»).
@Suite struct FileCipherTests {
    let fileId = UUID(uuidString: "0192F1E2-3B4C-7D5E-8F60-718293A4B5C6")!

    @Test func keyIsHKDFOfSyncKeyWithFileIdSaltAndVersionInfo() throws {
        let cipher = FileCipher(syncKey: testSyncKey)
        let saltBytes = withUnsafeBytes(of: fileId.uuid) { Data($0) }
        let expected = HKDF<SHA256>.deriveKey(inputKeyMaterial: testSyncKey, salt: saltBytes, info: Data("mynotion-file-v1".utf8),
                                              outputByteCount: 32)
        #expect(cipher.key(for: fileId) == expected)
        #expect(cipher.key(for: UUID()) != expected)
    }

    @Test func partIsNonceCiphertextTagWithFileIdIndexAndCountAuthenticated() throws {
        let cipher = FileCipher(syncKey: testSyncKey)
        let plain = sampleBytes(1_000)
        let sealed = try cipher.seal(plain, fileId: fileId, index: 2, count: 5)
        #expect(sealed.count == 12 + plain.count + 16)

        var context = withUnsafeBytes(of: fileId.uuid) { Data($0) }
        context.append(contentsOf: [0, 0, 0, 2, 0, 0, 0, 5])
        let box = try ChaChaPoly.SealedBox(combined: sealed)
        #expect(try ChaChaPoly.open(box, using: cipher.key(for: fileId), authenticating: context) == plain)
        #expect(try cipher.open(sealed, fileId: fileId, index: 2, count: 5) == plain)
    }

    @Test func filesAreCutIntoEightMegabyteParts() throws {
        let folder = try TemporaryFolder()
        let byteCount = 2 * AttachmentRef.partSize + 5
        let bytes = sampleBytes(byteCount)
        let url = try folder.file("большой.bin", bytes)
        let cipher = FileCipher(syncKey: testSyncKey)
        let ref = AttachmentRef(id: fileId, name: "большой.bin", byteCount: byteCount, contentType: "public.data",
                                sha256: try FileDigest.sha256(of: url))
        #expect(ref.partCount == 3)

        let parts = try (0..<3).map { try cipher.sealPart(ofFileAt: url, index: $0, ref: ref) }

        #expect(parts.map(\.count) == [AttachmentRef.partSize + 28, AttachmentRef.partSize + 28, 5 + 28])
        let opened = try parts.enumerated().map { try cipher.open($0.element, fileId: fileId, index: $0.offset, count: 3) }
        #expect(opened.reduce(Data(), +) == bytes)
    }

    @Test func tamperedSwappedOrTruncatedPartsDoNotOpen() throws {
        let cipher = FileCipher(syncKey: testSyncKey)
        let first = try cipher.seal(sampleBytes(500, seed: 1), fileId: fileId, index: 0, count: 2)
        let second = try cipher.seal(sampleBytes(500, seed: 2), fileId: fileId, index: 1, count: 2)

        var tampered = first
        tampered[40] ^= 0x01
        #expect(throws: FileCipherError.tampered) { try cipher.open(tampered, fileId: fileId, index: 0, count: 2) }
        // Переставленные части.
        #expect(throws: FileCipherError.tampered) { try cipher.open(second, fileId: fileId, index: 0, count: 2) }
        // Обрезанная часть и обрезанный файл (другое число частей).
        #expect(throws: FileCipherError.tampered) { try cipher.open(first.dropLast(1), fileId: fileId, index: 0, count: 2) }
        #expect(throws: FileCipherError.tampered) { try cipher.open(first, fileId: fileId, index: 0, count: 1) }
        // Часть чужого файла.
        #expect(throws: FileCipherError.tampered) { try cipher.open(first, fileId: UUID(), index: 0, count: 2) }
        // Другой ключ синхронизации.
        let stranger = FileCipher(syncKey: SymmetricKey(size: .bits256))
        #expect(throws: FileCipherError.tampered) { try stranger.open(first, fileId: fileId, index: 0, count: 2) }
    }

    @Test func digestMatchesSHA256OfTheWholeFile() throws {
        let folder = try TemporaryFolder()
        let bytes = sampleBytes(3 * 1_048_576 + 17)
        let url = try folder.file("x.bin", bytes)
        #expect(try FileDigest.sha256(of: url) == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
}
