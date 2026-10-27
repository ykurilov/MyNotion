import Foundation
import Synchronization
import Testing
@testable import Proofreading

/// Ключ DeepSeek, который синхронизация кладёт в связку ключей с другого устройства: виден сразу, без старого из памяти.
@Suite("Ключ DeepSeek в связке ключей")
struct ProofreadingKeychainTests {
    @Test("Ключ, заменённый синхронизацией, сразу виден «Исправить ошибки»; удалённый — пропадает")
    func replacedKeyIsVisible() async throws {
        let items = KeychainItemInMemory()
        let keychain = ProofreadingKeychain(storage: items.storage)
        try await keychain.save("  sk-old\n")
        #expect(try await keychain.key() == "sk-old")
        #expect(items.value == "sk-old")

        try keychain.replaceKey("sk-new")
        #expect(try await keychain.key() == "sk-new")
        #expect(items.value == "sk-new")

        try keychain.replaceKey(nil)
        #expect(try await keychain.key() == nil)
        #expect(items.value == nil)
    }

    @Test("Ключ для отправки читается из связки ключей, а не из памяти")
    func storedKeyReadsKeychain() async throws {
        let items = KeychainItemInMemory()
        let keychain = ProofreadingKeychain(storage: items.storage)
        try await keychain.save("sk-old")
        items.value = "sk-written-elsewhere"
        #expect(try keychain.storedKey() == "sk-written-elsewhere")
        #expect(try await keychain.key() == "sk-written-elsewhere")
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

    var storage: ProofreadingKeychain.Storage {
        ProofreadingKeychain.Storage(read: { [self] in value }, write: { [self] in value = $0 })
    }
}
