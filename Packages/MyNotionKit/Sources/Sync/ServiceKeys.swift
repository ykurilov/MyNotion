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
    /// Модели ИИ-агента через OpenRouter и запасной путь DeepSeek (модуль AIModels).
    public static let openRouter = "openrouter"
    public static let all = [deepSeek, notion, openRouter]
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
    private let refusing = Mutex(false)
    private let refusingReads = Mutex(false)
    private let reads = Mutex(0)

    public init(_ values: [String: String] = [:], names: [String] = ServiceKeyName.all) {
        self.names = names
        self.values = Mutex(values)
    }

    /// Связка ключей отказывает в записи — как заблокированная.
    public var refusesWrites: Bool {
        get { refusing.withLock { $0 } }
        set { refusing.withLock { $0 = newValue } }
    }

    /// Связка ключей не даёт читать — как после «Отказать» в вопросе macOS.
    public var refusesReads: Bool {
        get { refusingReads.withLock { $0 } }
        set { refusingReads.withLock { $0 = newValue } }
    }

    /// Сколько раз связку ключей спросили о ключе.
    public var readAttempts: Int { reads.withLock { $0 } }

    public func value(for name: String) throws -> String? {
        reads.withLock { $0 += 1 }
        if refusesReads { throw CocoaError(.fileReadNoPermission) }
        return values.withLock { $0[name] }
    }

    public func setValue(_ value: String?, for name: String) throws {
        if refusesWrites { throw CocoaError(.fileWriteNoPermission) }
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

/// Ключи сервисов этого устройства: ввод в настройках, запись пришедших в связку ключей и чтение для отправки.
/// Связка ключей — всегда после записи в базу, вне главного потока и по одному ключу: отказ связки или вопрос macOS
/// о доступе не держат ни базу, ни окно, ни приём страниц. Не легший ключ ждёт повтора; после перезапуска его
/// присылают снова.
public actor ServiceKeySync {
    /// Пришедший ключ лёг в связку ключей: настройкам перечитать, есть ли ключ.
    public static let didWriteKeys = Notification.Name("ServiceKeySync.didWriteKeys")

    public nonisolated let store: NotesStore
    public nonisolated let keys: any ServiceKeyStore
    private let retryDelay: Duration
    /// Победившие в базе версии, которые ещё не легли в связку ключей; по одной на ключ — самая новая.
    private var waiting: [String: ServiceKeyChange] = [:]
    private var retry: Task<Void, Never>?
    /// Связка ключей отказала в чтении (заблокирована или «Отказать» в вопросе macOS): до перезапуска или ввода ключа
    /// в настройках её не спрашивают — вопрос не всплывает на каждом круге синхронизации.
    private var readRefused = false

    public init(store: NotesStore, keys: any ServiceKeyStore, retryDelay: Duration = .seconds(30)) {
        self.store = store
        self.keys = keys
        self.retryDelay = retryDelay
    }

    /// Пустая строка удаляет ключ. Сначала метка в базе, потом связка ключей: не записалась база — ключ прежний;
    /// отказала связка — метка откатывается, и на другие устройства ничего не уходит. Ключ лёг, а база не сняла
    /// отметку «ждёт записи» — ключ остаётся новым, отметка снимается повтором, и он уходит на другие.
    public func save(_ value: String, for name: String) async throws {
        readRefused = false
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = try store.write { try ServiceKeys.recordLocalChange(of: name, value: value.isEmpty ? nil : value, in: $0) }
        do {
            // Пришедшая версия уже обошла правку — её ключ ляжет своей записью.
            if try ServiceKeys.isWaiting(local.change, in: store) { try keys.setValue(local.change.value, for: name) }
        } catch {
            try? ServiceKeys.revert(local, in: store)
            if let previous = local.previousWaiting, waiting[name]?.hlc != previous {
                // Ждавшую записи версию не знает память: другие пришлют её снова.
                try? store.write { try ServiceKeys.markForSending(requestingOthers: true, in: $0.database) }
            }
            throw error
        }
        do {
            try ServiceKeys.didWrite(local.change, in: store)
        } catch {
            waiting[name] = local.change
            scheduleRetry()
        }
        await MainActor.run { NotificationCenter.default.post(name: Outbox.didEnqueue, object: nil) }
    }

    /// Перед первым приёмом: ключам, лежавшим в связке ключей до синхронизации ключей, — самая ранняя метка;
    /// не легшим до перезапуска — повтор (`ServiceKeys.recoverWaiting`).
    /// `requestingOthers` — пачки уже шли без ключей: попросить другие прислать свои.
    func prepare(requestingOthers: Bool) throws {
        if try ServiceKeys.needsLabels(in: store) {
            let found = try ServiceKeys.unlabeled(keys.names, in: store).filter { try read($0) != nil }
            try store.write { try ServiceKeys.labelExisting(found, in: $0) }
        }
        let inMemory = Set(waiting.keys)
        try store.write { transaction in
            try ServiceKeys.recoverWaiting(except: inMemory, in: transaction)
            if requestingOthers { try ServiceKeys.markForSending(requestingOthers: true, in: transaction.database) }
        }
    }

    /// Версии, победившие при слиянии; транзакция уже закрыта.
    func writeReceived(_ changes: [ServiceKeyChange]) {
        for change in changes where waiting[change.name].map({ change.hlc > $0.hlc }) ?? true {
            waiting[change.name] = change
        }
        flush()
    }

    /// Ключи для пачки или снимка: с метками и уже лежащие в связке ключей.
    func current() throws -> [ServiceKeyChange] {
        try ServiceKeys.current(names: keys.names, value: { try read($0) }, in: store)
    }

    /// Для снимка: `nil`, пока пришедший ключ не лёг в связку ключей, — тогда получатель снимка попросит ключи сам.
    func currentForSnapshot() throws -> [ServiceKeyChange]? {
        try ServiceKeys.hasWaiting(in: store) ? nil : current()
    }

    private func flush() {
        var written: [ServiceKeyChange] = []
        var failed = false
        for (name, change) in waiting {
            do {
                if try write(change) { written.append(change) }
                waiting[name] = nil
            } catch {
                failed = true
            }
        }
        if failed { scheduleRetry() }
        if !written.isEmpty {
            let sendsOwn = written.contains { isOwn($0) }
            Task { @MainActor in
                NotificationCenter.default.post(name: Self.didWriteKeys, object: nil)
                if sendsOwn { NotificationCenter.default.post(name: Outbox.didEnqueue, object: nil) }
            }
        }
    }

    private func scheduleRetry() {
        guard retry == nil else { return }
        let delay = retryDelay
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.retryWaiting()
        }
    }

    private func retryWaiting() {
        retry = nil
        flush()
    }

    private func isOwn(_ change: ServiceKeyChange) -> Bool {
        change.hlc.deviceId == store.clock.deviceId
    }

    private func read(_ name: String) throws -> String? {
        if readRefused { throw CocoaError(.fileReadNoPermission) }
        do {
            return try keys.value(for: name)
        } catch {
            readRefused = true
            throw error
        }
    }

    /// `false` — эту версию уже обошла более новая: её ключ ляжет своей записью. Своя версия, дождавшаяся
    /// повтора, после записи уходит на другие устройства.
    @discardableResult
    private func write(_ change: ServiceKeyChange) throws -> Bool {
        guard try ServiceKeys.isWaiting(change, in: store) else { return false }
        try keys.setValue(change.value, for: change.name)
        try ServiceKeys.didWrite(change, in: store, send: isOwn(change))
        return true
    }
}

/// Метки ключей сервисов и отметки «отправить» в `app_meta` этого устройства — без самих ключей.
/// Ключ уходит внутри пачки, когда его правили здесь, когда устройство подключилось или обновилось (оно могло пропустить
/// ключи в журнале — тогда пачка ещё и просит другие прислать свои) и в ответ на такую просьбу. Ответ не просит,
/// поэтому просьбы не множатся.
///
/// Кто побеждает: поздняя метка, как у полей записей. Ключ, лежавший в связке ключей до синхронизации ключей, получает
/// самую раннюю метку (время 0 и id устройства): любая правка после обновления его обходит, а между двумя такими
/// ключами побеждает устройство с большим id.
enum ServiceKeys {
    static let metaPrefix = "sync.serviceKey"
    private static let clockPrefix = "sync.serviceKey.clock:"
    /// Версия победила в базе, но в связку ключей ещё не легла; значение — её метка.
    private static let waitingPrefix = "sync.serviceKey.waiting:"
    /// Пора отправить ключи; значение — номер отметки, чтобы не снять отметку, поставленную во время отправки.
    private static let sendMark = "sync.serviceKey.send"
    /// Попросить другие устройства прислать свои ключи.
    private static let requestMark = "sync.serviceKey.request"
    /// На этом устройстве синхронизация ключей уже началась (после обновления MyNotion — один раз).
    private static let introducedMark = "sync.serviceKey.introduced"
    /// Ключи, лежавшие в связке ключей до синхронизации ключей, получили метки.
    private static let labeledMark = "sync.serviceKey.labeled"

    struct Pending {
        let send: String
        let request: String?
    }

    /// Правка ключа на этом устройстве и то, что было до неё, — для отката.
    struct LocalChange {
        let change: ServiceKeyChange
        let previousClock: HybridTimestamp?
        let previousWaiting: HybridTimestamp?
    }

    static func recordLocalChange(of name: String, value: String?, in transaction: NotesTransaction) throws -> LocalChange {
        let db = transaction.database
        let local = LocalChange(change: ServiceKeyChange(name: name, value: value, hlc: transaction.clock.now()),
                                previousClock: try clock(of: name, in: db), previousWaiting: try waiting(of: name, in: db))
        try setClock(local.change.hlc, of: name, in: db)
        try setMeta(waitingPrefix + name, local.change.hlc.description, in: db)
        if try SyncAccountStore.isEnabled(in: db) {
            try markForSending(requestingOthers: false, in: db)
        }
        return local
    }

    /// Связка ключей не приняла правку: метка — как была, если её не обошла пришедшая версия.
    static func revert(_ local: LocalChange, in store: NotesStore) throws {
        try store.database.dbWriter.write { db in
            let name = local.change.name
            guard try clock(of: name, in: db) == local.change.hlc else { return }
            try setMeta(clockPrefix + name, local.previousClock?.description, in: db)
            try setMeta(waitingPrefix + name, local.previousWaiting?.description, in: db)
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

    static func needsLabels(in store: NotesStore) throws -> Bool {
        try store.database.dbWriter.read { try meta(labeledMark, in: $0) == nil }
    }

    static func unlabeled(_ names: [String], in store: NotesStore) throws -> [String] {
        try store.database.dbWriter.read { db in try names.filter { try clock(of: $0, in: db) == nil } }
    }

    /// Ключам, что уже лежат в связке ключей, — самая ранняя метка этого устройства; один раз.
    static func labelExisting(_ names: [String], in transaction: NotesTransaction) throws {
        let db = transaction.database
        for name in names where try clock(of: name, in: db) == nil {
            try setClock(HybridTimestamp(wallMillis: 0, counter: 0, deviceId: transaction.clock.deviceId), of: name, in: db)
        }
        try setMeta(labeledMark, "1", in: db)
    }

    /// Версии, не легшие в связку ключей до перезапуска. Своя: в связке ключей — либо она, либо прежний ключ; он и
    /// уходит с новой меткой, и все устройства сходятся к нему. Пришедшая: попросить другие прислать её снова.
    static func recoverWaiting(except inMemory: Set<String>, in transaction: NotesTransaction) throws {
        let db = transaction.database
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM app_meta WHERE key LIKE ?", arguments: [waitingPrefix + "%"])
        for row in rows {
            let name = String((row["key"] as String).dropFirst(waitingPrefix.count))
            guard !inMemory.contains(name), let hlc = HybridTimestamp(row["value"] as String) else { continue }
            if hlc.deviceId == transaction.clock.deviceId {
                try setClock(transaction.clock.now(), of: name, in: db)
                try setMeta(waitingPrefix + name, nil, in: db)
                try markForSending(requestingOthers: false, in: db)
            } else {
                try markForSending(requestingOthers: true, in: db)
            }
        }
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

    static func isWaiting(_ change: ServiceKeyChange, in store: NotesStore) throws -> Bool {
        try store.database.dbWriter.read { try waiting(of: change.name, in: $0) == change.hlc }
    }

    /// `send` — отправить ключ: своя версия легла не сразу, и отметку «отправить» могли уже снять.
    static func didWrite(_ change: ServiceKeyChange, in store: NotesStore, send: Bool = false) throws {
        try store.database.dbWriter.write { db in
            try db.execute(sql: "DELETE FROM app_meta WHERE key = ? AND value = ?",
                           arguments: [waitingPrefix + change.name, change.hlc.description])
            if send, try SyncAccountStore.isEnabled(in: db) { try markForSending(requestingOthers: false, in: db) }
        }
    }

    static func hasWaiting(in store: NotesStore) throws -> Bool {
        try store.database.dbWriter.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM app_meta WHERE key LIKE ?)", arguments: [waitingPrefix + "%"]) ?? false
        }
    }

    /// Ключи этого устройства с их метками — для пачки или снимка. Без метки ключа здесь нет; версия, ещё не легшая
    /// в связку ключей, не уходит: под её меткой там пока прежний ключ.
    static func current(keys: any ServiceKeyStore, in store: NotesStore) throws -> [ServiceKeyChange] {
        try current(names: keys.names, value: keys.value(for:), in: store)
    }

    static func current(names: [String], value: (String) throws -> String?, in store: NotesStore) throws -> [ServiceKeyChange] {
        let labels = try store.database.dbWriter.read { db in
            try names.compactMap { name -> (String, HybridTimestamp)? in
                guard try waiting(of: name, in: db) == nil, let hlc = try clock(of: name, in: db) else { return nil }
                return (name, hlc)
            }
        }
        return try labels.map { ServiceKeyChange(name: $0.0, value: try value($0.0), hlc: $0.1) }
    }

    /// Пришедшие ключи: побеждает поздняя метка (или та же, что не легла в связку ключей до перезапуска).
    /// Возвращает победившие версии — связке ключей после транзакции.
    static func merge(_ changes: [ServiceKeyChange]?, requestedByOthers: Bool, names: [String]?,
                      in transaction: NotesTransaction) throws -> [ServiceKeyChange] {
        guard let names else { return [] }
        let db = transaction.database
        let known = Set(names)
        var accepted: [String: ServiceKeyChange] = [:]
        for change in changes ?? [] {
            if change.hlc != .distantPast { transaction.clock.receive(change.hlc) }
            guard known.contains(change.name) else { continue }
            let local = try clock(of: change.name, in: db)
            let isNewer = local.map { change.hlc > $0 } ?? true
            let isMissing = try local == change.hlc && waiting(of: change.name, in: db) == change.hlc
            guard isNewer || isMissing else { continue }
            let value = change.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            let winner = ServiceKeyChange(name: change.name, value: value?.isEmpty == false ? value : nil, hlc: change.hlc)
            try setClock(winner.hlc, of: winner.name, in: db)
            try setMeta(waitingPrefix + winner.name, winner.hlc.description, in: db)
            accepted[winner.name] = winner
        }
        if requestedByOthers { try markForSending(requestingOthers: false, in: db) }
        return Array(accepted.values)
    }

    // MARK: Внутреннее

    private static func clock(of name: String, in db: Database) throws -> HybridTimestamp? {
        try meta(clockPrefix + name, in: db).flatMap(HybridTimestamp.init)
    }

    private static func waiting(of name: String, in db: Database) throws -> HybridTimestamp? {
        try meta(waitingPrefix + name, in: db).flatMap(HybridTimestamp.init)
    }

    private static func setClock(_ hlc: HybridTimestamp, of name: String, in db: Database) throws {
        try setMeta(clockPrefix + name, hlc.description, in: db)
    }

    private static func meta(_ key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key = ?", arguments: [key])
    }

    /// `nil` — убрать.
    private static func setMeta(_ key: String, _ value: String?, in db: Database) throws {
        guard let value else {
            return try db.execute(sql: "DELETE FROM app_meta WHERE key = ?", arguments: [key])
        }
        try db.execute(sql: "INSERT INTO app_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [key, value])
    }
}
