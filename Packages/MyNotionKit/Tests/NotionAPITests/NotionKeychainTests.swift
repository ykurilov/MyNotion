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
        try await keychain.save("  ntn_old\n")
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
        try await keychain.save("ntn_old")
        items.value = "ntn_written-elsewhere"
        #expect(try keychain.storedKey() == "ntn_written-elsewhere")
        #expect(try await keychain.key() == "ntn_written-elsewhere")
        try await keychain.save("")
        #expect(items.value == nil)
        #expect(try keychain.storedKey() == nil)
    }
}

/// Запись связки ключей в памяти.
final class KeychainItemInMemory: Sendable {
    private let stored = Mutex<String?>(nil)

    var value: String? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }

    var storage: NotionKeychain.Storage {
        NotionKeychain.Storage(read: { [self] in value }, write: { [self] in value = $0 })
    }
}
