import Foundation
import GRDB
import NotesCore
import Synchronization

/// Имена ключей сервисов в пачках — одни на всех устройствах.
public enum ServiceKeyName {
    /// «Исправить ошибки» (модуль Proofreading).
    public static let deepSeek = "deepseek"
    /// Картинки вставки из Notion (модуль NotionAPI).
    public static let notion = "notion"
    public static let all = [deepSeek, notion]
}

/// Ключи сервисов на этом устройстве — связка ключей. Синхронизация читает их только для зашифрованной пачки
/// или снимка и пишет сюда пришедшие с других устройств; в базу и файлы они не попадают.
public protocol ServiceKeyStore: Sendable {
    /// Какие ключи знает это устройство; ключи с другими именами (из более новой версии) пропускаются.
    var names: [String] { get }
    func value(for name: String) throws -> String?
    /// `nil` — удалить.
    func setValue(_ value: String?, for name: String) throws
}

/// Ключи сервисов в памяти — для тестов.
public final class InMemoryServiceKeys: ServiceKeyStore {
    public let names: [String]
    private let values: Mutex<[String: String]>

    public init(_ values: [String: String] = [:], names: [String] = ServiceKeyName.all) {
        self.names = names
        self.values = Mutex(values)
    }

    public func value(for name: String) throws -> String? {
        values.withLock { $0[name] }
    }

    public func setValue(_ value: String?, for name: String) throws {
        values.withLock { $0[name] = value }
    }
}

/// Ключ сервиса в пачке или снимке: значение и метка часов его последней правки; `value == nil` — ключ удалён.
/// Описание и отражение значение не показывают: ключ не попадёт в журнал даже случайно.
public struct ServiceKeyChange: Sendable, Hashable, Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var name: String
    public var value: String?
    public var hlc: HybridTimestamp

    public init(name: String, value: String?, hlc: HybridTimestamp) {
        self.name = name
        self.value = value
        self.hlc = hlc
    }

    public var description: String { "ServiceKeyChange(\(name), \(value == nil ? "удалён" : "••••"), \(hlc))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["name": name, "hlc": hlc]) }
}

/// Ввод и удаление ключа сервиса на этом устройстве: ключ — в связку ключей, метка часов — в базу,
/// на другие устройства он уходит внутри зашифрованной пачки.
public struct ServiceKeySync: Sendable {
    public let store: NotesStore
    public let keys: any ServiceKeyStore

    public init(store: NotesStore, keys: any ServiceKeyStore) {
        self.store = store
        self.keys = keys
    }

    /// Пустая строка удаляет ключ. Связка ключей — не на главном потоке: если macOS спросит доступ, окно не замрёт.
    public func save(_ value: String, for name: String) async throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = keys, store = store
        // Сначала ключ, потом метка: пришедший с другого устройства между ними получит метку раньше, и на всех
        // устройствах останется одно значение.
        try await Task.detached(priority: .userInitiated) {
            try keys.setValue(value.isEmpty ? nil : value, for: name)
            try store.write { try ServiceKeys.recordLocalChange(of: name, in: $0) }
        }.value
        await MainActor.run { NotificationCenter.default.post(name: Outbox.didEnqueue, object: nil) }
    }
}

/// Метки ключей сервисов и отметки «отправить» в `app_meta` этого устройства — без самих ключей.
/// Ключ уходит внутри пачки, когда его правили здесь, когда устройство подключилось или обновилось (оно могло пропустить
/// ключи в журнале — тогда пачка ещё и просит другие прислать свои) и в ответ на такую просьбу. Ответ не просит,
/// поэтому просьбы не множатся. Две правки одного ключа сходятся по метке, как поля записей.
enum ServiceKeys {
    static let metaPrefix = "sync.serviceKey"
    private static let clockPrefix = "sync.serviceKey.clock:"
    /// Пора отправить ключи; значение — номер отметки, чтобы не снять отметку, поставленную во время отправки.
    private static let sendMark = "sync.serviceKey.send"
    /// Попросить другие устройства прислать свои ключи.
    private static let requestMark = "sync.serviceKey.request"
    /// На этом устройстве синхронизация ключей уже началась (после обновления MyNotion — один раз).
    private static let introducedMark = "sync.serviceKey.introduced"

    struct Pending {
        let send: String
        let request: String?
    }

    static func recordLocalChange(of name: String, in transaction: NotesTransaction) throws {
        try setClock(transaction.clock.now(), of: name, in: transaction.database)
        if try SyncAccountStore.isEnabled(in: transaction.database) {
            try markForSending(requestingOthers: false, in: transaction.database)
        }
    }

    static func markForSending(requestingOthers: Bool, in db: Database) throws {
        let mark = UUID().uuidString
        try setMeta(sendMark, mark, in: db)
        if requestingOthers { try setMeta(requestMark, mark, in: db) }
    }

    /// Подключили устройство (или включили синхронизацию снова).
    static func introduce(in db: Database) throws {
        try markForSending(requestingOthers: true, in: db)
        try setMeta(introducedMark, "1", in: db)
    }

    /// Первый запуск версии с синхронизацией ключей на уже подключённом устройстве: его ключи уходят на другие,
    /// а ключи, которые оно пропустило, пока было старым, приходят в ответ.
    static func introduceIfNeeded(in db: Database) throws {
        guard try meta(introducedMark, in: db) == nil else { return }
        try introduce(in: db)
    }

    /// Синхронизацию выключили: отправлять больше некуда. Метки ключей остаются.
    static func forgetPending(in db: Database) throws {
        try db.execute(sql: "DELETE FROM app_meta WHERE key IN (?, ?)", arguments: [sendMark, requestMark])
    }

    static func pending(in store: NotesStore) throws -> Pending? {
        try store.database.dbWriter.read { db in
            try meta(sendMark, in: db).map { Pending(send: $0, request: try meta(requestMark, in: db)) }
        }
    }

    /// Пачка с ключами принята сервером: отметки, поставленные во время отправки, остаются.
    static func didSend(_ pending: Pending, in store: NotesStore) throws {
        try store.database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM app_meta WHERE key = ? AND value = ?", arguments: [sendMark, pending.send])
            if let request = pending.request {
                try db.execute(sql: "DELETE FROM app_meta WHERE key = ? AND value = ?", arguments: [requestMark, request])
            }
        }
    }

    /// Ключи этого устройства с их метками — для пачки или снимка. Ключ, введённый до синхронизации ключей, получает
    /// метку сейчас; ключ без значения и без метки здесь не вводили — о нём устройство молчит.
    static func current(keys: any ServiceKeyStore, in store: NotesStore) throws -> [ServiceKeyChange] {
        try keys.names.compactMap { name -> ServiceKeyChange? in
            let value = try keys.value(for: name)
            let stored = try store.database.dbWriter.read { try clock(of: name, in: $0) }
            if let stored { return ServiceKeyChange(name: name, value: value, hlc: stored) }
            guard let value else { return nil }
            let hlc = try store.write { transaction -> HybridTimestamp in
                // Пока читали связку ключей, метку мог поставить пришедший ключ — тогда берётся она.
                if let stamped = try clock(of: name, in: transaction.database) { return stamped }
                let now = transaction.clock.now()
                try setClock(now, of: name, in: transaction.database)
                return now
            }
            return ServiceKeyChange(name: name, value: try keys.value(for: name), hlc: hlc)
        }
    }

    /// Пришедшие ключи: побеждает поздняя метка, победивший ложится в связку ключей. Возвращает поменявшиеся имена.
    static func merge(_ changes: [ServiceKeyChange]?, requestedByOthers: Bool, keys: (any ServiceKeyStore)?,
                      in transaction: NotesTransaction) throws -> Set<String> {
        guard let keys else { return [] }
        let db = transaction.database
        let known = Set(keys.names)
        var changed: Set<String> = []
        for change in changes ?? [] {
            if change.hlc != .distantPast { transaction.clock.receive(change.hlc) }
            guard known.contains(change.name),
                  try clock(of: change.name, in: db).map({ change.hlc > $0 }) ?? true else { continue }
            let value = change.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            try keys.setValue(value?.isEmpty == false ? value : nil, for: change.name)
            try setClock(change.hlc, of: change.name, in: db)
            changed.insert(change.name)
        }
        if requestedByOthers { try markForSending(requestingOthers: false, in: db) }
        return changed
    }

    // MARK: Внутреннее

    private static func clock(of name: String, in db: Database) throws -> HybridTimestamp? {
        try meta(clockPrefix + name, in: db).flatMap(HybridTimestamp.init)
    }

    private static func setClock(_ hlc: HybridTimestamp, of name: String, in db: Database) throws {
        try setMeta(clockPrefix + name, hlc.description, in: db)
    }

    private static func meta(_ key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key = ?", arguments: [key])
    }

    private static func setMeta(_ key: String, _ value: String, in db: Database) throws {
        try db.execute(sql: "INSERT INTO app_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [key, value])
    }
}
