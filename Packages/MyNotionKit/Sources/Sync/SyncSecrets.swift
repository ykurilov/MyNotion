import CryptoKit
import Foundation
import Synchronization

/// Токен устройства и ключ шифрования записей (research R9). В приложении — связка ключей (`SyncKeychain`).
public struct SyncSecretValues: Sendable {
    public var deviceToken: String
    public var encryptionKey: SymmetricKey

    public init(deviceToken: String, encryptionKey: SymmetricKey) {
        self.deviceToken = deviceToken
        self.encryptionKey = encryptionKey
    }
}

/// Где лежат секреты подключения; ключ записи — id устройства на сервере, чтобы у каждой базы были свои.
public protocol SyncSecrets: Sendable {
    func save(_ values: SyncSecretValues, for deviceId: String) throws
    func load(for deviceId: String) throws -> SyncSecretValues?
    func delete(for deviceId: String) throws
}

/// Секреты в памяти — для тестов.
public final class InMemorySyncSecrets: SyncSecrets {
    private let values = Mutex<[String: SyncSecretValues]>([:])

    public init() {}

    public func save(_ values: SyncSecretValues, for deviceId: String) throws {
        self.values.withLock { $0[deviceId] = values }
    }

    public func load(for deviceId: String) throws -> SyncSecretValues? {
        values.withLock { $0[deviceId] }
    }

    public func delete(for deviceId: String) throws {
        _ = values.withLock { $0.removeValue(forKey: deviceId) }
    }
}
