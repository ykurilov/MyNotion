import CryptoKit
import Foundation
import Security

/// Токен устройства и ключ шифрования в связке ключей Mac (research R9): только на этом Mac, не в базе и не в файлах.
public struct SyncKeychain: SyncSecrets {
    public static let service = "cloud.kurilov.mynotion.sync"
    public let service: String

    public init(service: String = SyncKeychain.service) {
        self.service = service
    }

    public func save(_ values: SyncSecretValues, for deviceId: String) throws {
        let key = values.encryptionKey.withUnsafeBytes { Data($0) }
        try write(Data(values.deviceToken.utf8), account: "\(deviceId).token")
        try write(key, account: "\(deviceId).key")
    }

    public func load(for deviceId: String) throws -> SyncSecretValues? {
        guard let token = try read(account: "\(deviceId).token"), let key = try read(account: "\(deviceId).key") else { return nil }
        return SyncSecretValues(deviceToken: String(decoding: token, as: UTF8.self), encryptionKey: SymmetricKey(data: key))
    }

    public func delete(for deviceId: String) throws {
        for account in ["\(deviceId).token", "\(deviceId).key"] {
            let status = SecItemDelete(query(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SyncKeychainError(status: status) }
        }
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func write(_ data: Data, account: String) throws {
        let base = query(account: account)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SyncKeychainError(status: update) }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "MyNotion — синхронизация"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw SyncKeychainError(status: added) }
    }

    private func read(account: String) throws -> Data? {
        var item = query(account: account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SyncKeychainError(status: status) }
        return result as? Data
    }
}

public struct SyncKeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Связка ключей не ответила: \(SecCopyErrorMessageString(status, nil) as String? ?? "код \(status)")"
    }
}
