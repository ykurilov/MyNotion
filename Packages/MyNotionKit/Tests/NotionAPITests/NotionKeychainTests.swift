import Foundation
import Synchronization
import Testing
@testable import NotionAPI

/// Ключ интеграции Notion, который синхронизация кладёт в связку ключей с другого устройства: виден сразу, без старого из памяти.
@Suite("Ключ интеграции Notion в связке ключей")
struct NotionKeychainTests {
    @Test("Ключ, заменённый синхронизацией, сразу виден вставке картинок из Notion; удалённый — пропадает")
    func replacedKeyIsVisible() async throws {
        let items = KeychainItemInMemory()
        let keychain = NotionKeychain(storage: items.storage)
        try keychain.replaceKey("ntn_old")
        #expect(try await keychain.key() == "ntn_old")
        #expect(items.value == "ntn_old")

        try keychain.replaceKey("ntn_new")
        #expect(try await keychain.key() == "ntn_new")
        #expect(items.value == "ntn_new")

        try keychain.replaceKey(nil)
        #expect(try await keychain.key() == nil)
        #expect(items.value == nil)
    }

    @Test("Ключ для отправки читается из связки ключей, а не из памяти")
    func storedKeyReadsKeychain() async throws {
        let items = KeychainItemInMemory()
        let keychain = NotionKeychain(storage: items.storage)
        try keychain.replaceKey("ntn_old")
        items.value = "ntn_written-elsewhere"
        #expect(try keychain.storedKey() == "ntn_written-elsewhere")
        #expect(try await keychain.key() == "ntn_written-elsewhere")
        try keychain.replaceKey(nil)
        #expect(items.value == nil)
        #expect(try keychain.storedKey() == nil)
    }

    @Test("Чтение, начатое до замены ключа, не возвращает в память старый ключ")
    func readBeforeReplaceDoesNotRestoreOldKey() async throws {
        let items = KeychainItemInMemory()
        items.value = "ntn_old"
        let keychain = NotionKeychain(storage: items.storage)
        items.whileReading = { try? keychain.replaceKey("ntn_new") }
        _ = try await keychain.key()
        items.whileReading = nil
        #expect(try await keychain.key() == "ntn_new")
    }
}

/// Запись связки ключей в памяти.
final class KeychainItemInMemory: Sendable {
    private let stored = Mutex<String?>(nil)
    private let hook = Mutex<(@Sendable () -> Void)?>(nil)

    /// Вызывается посреди чтения: значение уже прочитано, но ещё не отдано.
    var whileReading: (@Sendable () -> Void)? {
        get { hook.withLock { $0 } }
        set { hook.withLock { $0 = newValue } }
    }

    var value: String? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }

    var storage: NotionKeychain.Storage {
        NotionKeychain.Storage(read: { [self] in
            let read = value
            whileReading?()
            return read
        }, write: { [self] in value = $0 })
    }
}
