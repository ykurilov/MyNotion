import CryptoKit
import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Шифрование пачек (research R9): ChaChaPoly, свой nonce на каждую пачку, id устройства и пачки проверяются вместе с текстом.
@Suite("Шифрование пачек")
struct BatchCipherTests {
    let cipher = BatchCipher(key: SymmetricKey(size: .bits256))
    let deviceId = UUID().uuidString.lowercased()

    func batch(text: String = "секретная заметка") -> SyncBatch {
        let clock = HybridLogicalClock(deviceId: UUID())
        return SyncBatch(deviceId: deviceId, deviceName: "Mac A", changes: [
            SyncChange(entity: .block, id: UUID(), pageId: UUID(), value: .text(InlineText(text)), hlc: clock.now()),
        ])
    }

    @Test("Пачка шифруется и расшифровывается тем же ключом; на сервере текста не видно")
    func roundTrip() throws {
        let original = batch()
        let sealed = try cipher.seal(original, batchId: "b1")
        let opened = try cipher.open(sealed, batchId: "b1", deviceId: deviceId)
        #expect(opened == original)
        let onServer = try #require(Data(base64Encoded: sealed))
        #expect(!String(decoding: onServer, as: UTF8.self).contains("секретная"))
    }

    @Test("У каждой пачки свой nonce: одна и та же пачка дважды даёт разный шифротекст")
    func noncePerBatch() throws {
        let original = batch()
        let first = try #require(Data(base64Encoded: try cipher.seal(original, batchId: "b1")))
        let second = try #require(Data(base64Encoded: try cipher.seal(original, batchId: "b1")))
        #expect(first != second)
        #expect(first.prefix(12) != second.prefix(12), "Первые 12 байт — nonce ChaChaPoly")
    }

    @Test("Пачку, выданную за чужую (другой id пачки или устройства), Mac отвергает")
    func idsAreAuthenticated() throws {
        let sealed = try cipher.seal(batch(), batchId: "b1")
        #expect(throws: BatchCipherError.tampered) { try cipher.open(sealed, batchId: "b2", deviceId: deviceId) }
        #expect(throws: BatchCipherError.tampered) { try cipher.open(sealed, batchId: "b1", deviceId: UUID().uuidString) }
    }

    @Test("Подменённая пачка и чужой ключ отвергаются")
    func tamperedBatchIsRejected() throws {
        var bytes = try #require(Data(base64Encoded: try cipher.seal(batch(), batchId: "b1")))
        bytes[bytes.count / 2] ^= 0x01
        #expect(throws: BatchCipherError.tampered) {
            try cipher.open(bytes.base64EncodedString(), batchId: "b1", deviceId: deviceId)
        }
        let stranger = BatchCipher(key: SymmetricKey(size: .bits256))
        #expect(throws: BatchCipherError.tampered) {
            try stranger.open(try cipher.seal(batch(), batchId: "b1"), batchId: "b1", deviceId: deviceId)
        }
    }

    @Test("Внутри пачки id устройства должен совпадать с тем, кто её отправил")
    func payloadDeviceMustMatchSender() throws {
        var forged = batch()
        forged.deviceId = UUID().uuidString.lowercased()
        let sealed = try cipher.seal(forged, batchId: "b1", senderDeviceId: deviceId)
        #expect(throws: BatchCipherError.tampered) { try cipher.open(sealed, batchId: "b1", deviceId: deviceId) }
    }

    @Test("Пачка новее известного формата не применяется: она ждёт, Юрий видит «обновите MyNotion на этом Mac»")
    func newerFormatWaits() throws {
        var future = batch()
        future.formatVersion = SyncBatch.currentFormatVersion + 1
        let sealed = try cipher.seal(future, batchId: "b1")
        #expect(throws: BatchCipherError.newerFormat(SyncBatch.currentFormatVersion + 1)) {
            try cipher.open(sealed, batchId: "b1", deviceId: deviceId)
        }
        let message = BatchCipherError.newerFormat(2).localizedDescription
        #expect(message.localizedCaseInsensitiveContains("обновите MyNotion на этом Mac"))
    }

    @Test("Ключ шифрования переживает перевод в код подключения и обратно")
    func keyRoundTripsThroughJoinCode() throws {
        let key = SymmetricKey(size: .bits256)
        let code = JoinCode(inviteCode: "7K2M9QXH4TVBN8RZC3JW", encryptionKey: key)
        let typed = code.text.lowercased().replacingOccurrences(of: "-", with: " ")
        let parsed = try JoinCode(parsing: typed)
        #expect(parsed.inviteCode == "7K2M9QXH4TVBN8RZC3JW")
        #expect(parsed.encryptionKey.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
        var broken = Array(code.text)
        let index = try #require(broken.firstIndex { $0 != "-" && $0 != "0" })
        broken[index] = broken[index] == "1" ? "2" : "1"
        #expect(throws: JoinCodeError.mistyped) { try JoinCode(parsing: String(broken)) }
    }
}
