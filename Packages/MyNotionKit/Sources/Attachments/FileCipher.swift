import CryptoKit
import Foundation
import NotesCore

/// Шифрование частей файла для сервера (contracts/sync-and-files-api.md, «Шифрование»): ключ файла —
/// HKDF-SHA256(ключ синхронизации, соль = id файла, `mynotion-file-v1`); часть — ChaChaPoly со своим nonce,
/// `nonce (12) ‖ шифротекст ‖ тег (16)`. В проверяемые данные входят id файла, номер части и число частей —
/// часть нельзя подменить, переставить или обрезать. Сервер видит только размеры частей.
public struct FileCipher: Sendable {
    let syncKey: SymmetricKey

    public init(syncKey: SymmetricKey) {
        self.syncKey = syncKey
    }

    public func key(for fileId: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: syncKey, salt: Self.bytes(of: fileId), info: Data("mynotion-file-v1".utf8),
                               outputByteCount: 32)
    }

    public func seal(_ plaintext: Data, fileId: UUID, index: Int, count: Int) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key(for: fileId), authenticating: Self.context(fileId: fileId, index: index, count: count))
            .combined
    }

    public func open(_ sealed: Data, fileId: UUID, index: Int, count: Int) throws -> Data {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let plaintext = try? ChaChaPoly.open(box, using: key(for: fileId),
                                                   authenticating: Self.context(fileId: fileId, index: index, count: count))
        else { throw FileCipherError.tampered }
        return plaintext
    }

    /// Часть `index` файла на диске, зашифрованная: читается только её кусок, не весь файл.
    public func sealPart(ofFileAt url: URL, index: Int, ref: AttachmentRef) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index * AttachmentRef.partSize))
        let plaintext = try handle.read(upToCount: AttachmentRef.partSize) ?? Data()
        return try seal(plaintext, fileId: ref.id, index: index, count: ref.partCount)
    }

    /// `id файла (16) ‖ номер части (u32) ‖ число частей (u32)`, числа — старшим байтом вперёд.
    static func context(fileId: UUID, index: Int, count: Int) -> Data {
        var data = bytes(of: fileId)
        withUnsafeBytes(of: UInt32(index).bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(count).bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func bytes(of id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }
}

public enum FileCipherError: Error, Equatable {
    /// Часть подменена, переставлена, обрезана или зашифрована другим ключом.
    case tampered
}

/// SHA-256 файла кусками по 1 МБ.
public enum FileDigest {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return AttachmentStore.hex(hasher.finalize())
    }
}
