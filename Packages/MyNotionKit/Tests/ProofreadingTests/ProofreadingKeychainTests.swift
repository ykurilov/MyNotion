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
        try keychain.replaceKey("sk-old")
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
        try keychain.replaceKey("sk-old")
        items.value = "sk-written-elsewhere"
        #expect(try keychain.storedKey() == "sk-written-elsewhere")
        #expect(try await keychain.key() == "sk-written-elsewhere")
        try keychain.replaceKey(nil)
        #expect(items.value == nil)
        #expect(try keychain.storedKey() == nil)
    }

    @Test("Чтение, начатое до замены ключа, не возвращает в память старый ключ")
    func readBeforeReplaceDoesNotRestoreOldKey() async throws {
        let items = KeychainItemInMemory()
        items.value = "sk-old"
        let keychain = ProofreadingKeychain(storage: items.storage)
        items.whileReading = { try? keychain.replaceKey("sk-new") }
        _ = try await keychain.key()
        items.whileReading = nil
        #expect(try await keychain.key() == "sk-new")
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

    var storage: ProofreadingKeychain.Storage {
        ProofreadingKeychain.Storage(read: { [self] in
            let read = value
            whileReading?()
            return read
        }, write: { [self] in value = $0 })
    }
}
