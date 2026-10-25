import Foundation
import Security
import Synchronization

/// Ключ DeepSeek в связке ключей Mac: не в базе, не в файлах и не в журналах. Читается при первой проверке текста,
/// не на главном потоке: если macOS спросит доступ, окно не замрёт.
public final class ProofreadingKeychain: Sendable {
    public static let service = "cloud.kurilov.mynotion.deepseek"
    public static let account = "api-key"

    private let service: String
    /// Прочитанный ключ: связка ключей спрашивается один раз за запуск.
    private let cached = Mutex<String?>(nil)

    public init(service: String = ProofreadingKeychain.service) {
        self.service = service
    }

    public func key() async throws -> String? {
        if let key = cached.withLock({ $0 }) { return key }
        let service = service
        let key = try await Task.detached(priority: .userInitiated) { try Self.read(service: service) }.value
        cached.withLock { $0 = key }
        return key
    }

    /// Пустая строка удаляет ключ.
    public func save(_ key: String) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = service
        try await Task.detached(priority: .userInitiated) {
            if key.isEmpty { try Self.delete(service: service) } else { try Self.write(Data(key.utf8), service: service) }
        }.value
        cached.withLock { $0 = key.isEmpty ? nil : key }
    }

    private static func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(service: String) throws -> String? {
        var item = query(service: service)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ProofreadingKeychainError(status: status) }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private static func write(_ data: Data, service: String) throws {
        let base = query(service: service)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw ProofreadingKeychainError(status: update) }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MyNotion — ключ DeepSeek"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw ProofreadingKeychainError(status: added) }
    }

    private static func delete(service: String) throws {
        let status = SecItemDelete(query(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ProofreadingKeychainError(status: status) }
    }
}

public struct ProofreadingKeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Связка ключей не ответила: \(SecCopyErrorMessageString(status, nil) as String? ?? "код \(status)")"
    }
}
