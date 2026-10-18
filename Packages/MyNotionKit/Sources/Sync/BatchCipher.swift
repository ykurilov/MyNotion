import CryptoKit
import Foundation

/// Шифрование пачек и снимков (research R9): ChaChaPoly, свой случайный nonce на каждую пачку;
/// id устройства-отправителя и id пачки входят в проверяемые данные — пачку нельзя выдать за чужую.
public struct BatchCipher: Sendable {
    let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// Зашифровать пачку для `POST /changes`; результат — base64.
    public func seal(_ batch: SyncBatch, batchId: String, senderDeviceId: String? = nil) throws -> String {
        let plaintext = try SyncJSON.encoder().encode(batch)
        let box = try ChaChaPoly.seal(plaintext, using: key,
                                      authenticating: Self.batchContext(deviceId: senderDeviceId ?? batch.deviceId, batchId: batchId))
        return box.combined.base64EncodedString()
    }

    /// Расшифровать пачку из журнала. `deviceId` и `batchId` — как их отдал сервер.
    public func open(_ ciphertext: String, batchId: String, deviceId: String) throws -> SyncBatch {
        let plaintext = try open(ciphertext, context: Self.batchContext(deviceId: deviceId, batchId: batchId))
        let batch = try decodeChecked(SyncBatch.self, from: plaintext)
        guard batch.deviceId == deviceId else { throw BatchCipherError.tampered }
        return batch
    }

    public func sealSnapshot(_ snapshot: SyncSnapshot) throws -> String {
        let box = try ChaChaPoly.seal(try SyncJSON.encoder().encode(snapshot), using: key,
                                      authenticating: Self.snapshotContext(seq: snapshot.seq))
        return box.combined.base64EncodedString()
    }

    public func openSnapshot(_ ciphertext: String, seq: Int) throws -> SyncSnapshot {
        let snapshot = try decodeChecked(SyncSnapshot.self, from: try open(ciphertext, context: Self.snapshotContext(seq: seq)))
        guard snapshot.seq == seq else { throw BatchCipherError.tampered }
        return snapshot
    }

    // MARK: Внутреннее

    private func open(_ ciphertext: String, context: Data) throws -> Data {
        guard let combined = Data(base64Encoded: ciphertext),
              let box = try? ChaChaPoly.SealedBox(combined: combined),
              let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: context)
        else { throw BatchCipherError.tampered }
        return plaintext
    }

    /// Сначала версия формата: пачку новее этого Mac не разбираем, а ждём обновления.
    private func decodeChecked<T: Decodable>(_ type: T.Type, from plaintext: Data) throws -> T {
        guard let header = try? SyncJSON.decoder().decode(FormatHeader.self, from: plaintext) else { throw BatchCipherError.tampered }
        guard header.formatVersion <= SyncBatch.currentFormatVersion else {
            throw BatchCipherError.newerFormat(header.formatVersion)
        }
        guard let value = try? SyncJSON.decoder().decode(type, from: plaintext) else { throw BatchCipherError.tampered }
        return value
    }

    private struct FormatHeader: Decodable { let formatVersion: Int }

    private static func batchContext(deviceId: String, batchId: String) -> Data {
        Data("mynotion-batch\u{0}\(deviceId)\u{0}\(batchId)".utf8)
    }

    private static func snapshotContext(seq: Int) -> Data {
        Data("mynotion-snapshot\u{0}\(seq)".utf8)
    }
}

public enum BatchCipherError: Error, Equatable, LocalizedError {
    /// Пачка подменена, повреждена или зашифрована другим ключом.
    case tampered
    /// Пачка записана более новой версией MyNotion.
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .tampered: "Правки с другого Mac не открылись — похоже, этот Mac подключён другим кодом. Подключите его заново кодом с другого Mac"
        case .newerFormat: "Правки пришли из более новой версии MyNotion — обновите MyNotion на этом Mac"
        }
    }
}
