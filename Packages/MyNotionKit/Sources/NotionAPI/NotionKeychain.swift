import Foundation
import Security
import Synchronization

/// Ключ интеграции Notion в связке ключей Mac: не в базе, не в файлах и не в журналах. Читается при первой вставке
/// картинки из Notion, не на главном потоке: если macOS спросит доступ, окно не замрёт.
public final class NotionKeychain: Sendable {
    public static let service = "cloud.kurilov.mynotion.notion"
    public static let account = "api-key"

    /// Где лежит ключ: связка ключей, в тестах — память.
    struct Storage: Sendable {
        let read: @Sendable () throws -> String?
        /// `nil` — удалить.
        let write: @Sendable (String?) throws -> Void
    }

    private let storage: Storage
    /// Прочитанный ключ: связка ключей спрашивается один раз за запуск. Поколение растёт с каждой заменой ключа:
    /// чтение, начатое до замены, старый ключ в память не вернёт.
    private let cached = Mutex<(key: String?, generation: Int)>((nil, 0))

    public convenience init(service: String = NotionKeychain.service) {
        self.init(storage: Storage(read: { try NotionKeychain.read(service: service) }, write: { key in
            if let key { try NotionKeychain.write(Data(key.utf8), service: service) } else { try NotionKeychain.delete(service: service) }
        }))
    }

    init(storage: Storage) {
        self.storage = storage
    }

    public func key() async throws -> String? {
        if let key = cached.withLock({ $0.key }) { return key }
        return try await Task.detached(priority: .userInitiated) { [self] in try storedKey() }.value
    }

    /// Ключ из связки ключей на вызывающем потоке, мимо памяти, — для синхронизации между устройствами.
    package func storedKey() throws -> String? {
        let generation = cached.withLock { $0.generation }
        let key = try storage.read()
        cached.withLock { if $0.generation == generation { $0.key = key } }
        return key
    }

    /// Новый ключ — только через синхронизацию ключей (`ServiceKeySync`), иначе устройства разойдутся.
    /// На вызывающем потоке; `nil` — удалить. Старый в памяти не остаётся.
    package func replaceKey(_ key: String?) throws {
        try storage.write(key)
        cached.withLock { $0 = (key, $0.generation + 1) }
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
        guard status == errSecSuccess, let data = result as? Data else { throw NotionKeychainError(status: status) }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private static func write(_ data: Data, service: String) throws {
        let base = query(service: service)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NotionKeychainError(status: update) }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "MyNotion — ключ интеграции Notion"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw NotionKeychainError(status: added) }
    }

    private static func delete(service: String) throws {
        let status = SecItemDelete(query(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NotionKeychainError(status: status) }
    }
}

public struct NotionKeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        "Связка ключей не ответила: \(SecCopyErrorMessageString(status, nil) as String? ?? "код \(status)")"
    }
}
