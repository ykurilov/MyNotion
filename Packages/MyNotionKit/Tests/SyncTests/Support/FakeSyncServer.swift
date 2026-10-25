import Foundation
@testable import Sync

/// Сервер синхронизации в памяти — строго по contracts/sync-api.md: журнал пачек с номерами, повтор `batchId`,
/// долгое ожидание, подтверждения, снимок и сжатие журнала, приглашения на 15 минут и одно использование.
actor FakeSyncServer: SyncServer {
    private struct Device {
        let id: String
        let name: String
        let token: String
        var lastAckSeq: Int
        var lastSeenAt = Date()
        var isActive = true
    }

    private struct Invite {
        let expiresAt: Date
        var used = false
    }

    private var devices: [Device] = []
    private var invites: [String: Invite] = [:]
    private var journal: [SyncJournalItem] = []
    private var nextSeq = 1
    private var compactedThrough = 0
    private var storedSnapshot: SyncSnapshotEnvelope?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// `mynotion-sync bootstrap`: первое устройство и его токен; когда устройства уже есть — отказ, как у сервера.
    func bootstrap(name: String) throws -> String {
        guard devices.isEmpty else { throw SyncServerError.badRequest("Первое устройство уже есть") }
        return createDevice(name: name, ackSeq: 0).token
    }

    var lastSeq: Int { nextSeq - 1 }
    var journalCount: Int { journal.count }
    var compactedSeq: Int { compactedThrough }

    nonisolated func transport(deviceToken: String) -> any SyncTransport {
        FakeSyncTransport(server: self, token: deviceToken)
    }

    func join(inviteCode: String, deviceName: String) throws -> SyncJoinResult {
        guard var invite = invites[inviteCode], !invite.used, invite.expiresAt > now() else {
            throw SyncServerError.inviteExpired
        }
        invite.used = true
        invites[inviteCode] = invite
        let latest = storedSnapshot?.seq
        let device = createDevice(name: deviceName, ackSeq: latest ?? 0)
        return SyncJoinResult(deviceId: device.id, deviceToken: device.token, latestSnapshotSeq: latest)
    }

    // MARK: Запросы устройства

    fileprivate func authenticate(_ token: String) throws -> Int {
        guard let index = devices.firstIndex(where: { $0.token == token && $0.isActive }) else {
            throw SyncServerError.unauthorized
        }
        devices[index].lastSeenAt = now()
        return index
    }

    fileprivate func invite(token: String) throws -> SyncInvite {
        _ = try authenticate(token)
        let code = String((0..<20).map { _ in "0123456789ABCDEFGHJKMNPQRSTVWXYZ".randomElement()! })
        let expiresAt = now().addingTimeInterval(15 * 60)
        invites[code] = Invite(expiresAt: expiresAt)
        return SyncInvite(inviteCode: code, expiresAt: expiresAt)
    }

    fileprivate func listDevices(token: String) throws -> [SyncDevice] {
        _ = try authenticate(token)
        return devices.filter(\.isActive).map {
            SyncDevice(deviceId: $0.id, deviceName: $0.name, lastSeenAt: $0.lastSeenAt, lastAckSeq: $0.lastAckSeq)
        }
    }

    fileprivate func currentDevice(token: String) throws -> SyncDevice {
        let device = devices[try authenticate(token)]
        return SyncDevice(deviceId: device.id, deviceName: device.name, lastSeenAt: device.lastSeenAt, lastAckSeq: device.lastAckSeq)
    }

    fileprivate func disable(token: String, deviceId: String) throws {
        _ = try authenticate(token)
        guard let index = devices.firstIndex(where: { $0.id == deviceId }) else { throw SyncServerError.notFound }
        devices[index].isActive = false
        compact()
    }

    fileprivate func post(token: String, batchId: String, ciphertext: String) throws -> Int {
        let index = try authenticate(token)
        if let existing = journal.first(where: { $0.batchId == batchId }) { return existing.seq }
        guard ciphertext.utf8.count * 3 / 4 <= 4 * 1024 * 1024 else { throw SyncServerError.tooLarge }
        let item = SyncJournalItem(seq: nextSeq, batchId: batchId, deviceId: devices[index].id, ciphertext: ciphertext)
        nextSeq += 1
        journal.append(item)
        for waiter in waiters.values { waiter.resume() }
        waiters.removeAll()
        return item.seq
    }

    fileprivate func read(token: String, after: Int, wait: Int) async throws -> SyncChangesPage {
        _ = try authenticate(token)
        if after < compactedThrough { throw SyncServerError.logCompacted(snapshotSeq: storedSnapshot?.seq ?? compactedThrough) }
        if let page = itemsPage(after: after) { return page }
        guard wait > 0 else { return SyncChangesPage(items: [], hasMore: false) }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(min(wait, 25)))
                    await self?.wake(id)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.wake(id) }
        }
        if after < compactedThrough { throw SyncServerError.logCompacted(snapshotSeq: storedSnapshot?.seq ?? compactedThrough) }
        return itemsPage(after: after) ?? SyncChangesPage(items: [], hasMore: false)
    }

    fileprivate func ack(token: String, seq: Int) throws {
        let index = try authenticate(token)
        devices[index].lastAckSeq = max(devices[index].lastAckSeq, min(seq, lastSeq))
        compact()
    }

    fileprivate func putSnapshot(token: String, seq: Int, ciphertext: String) throws {
        _ = try authenticate(token)
        storedSnapshot = SyncSnapshotEnvelope(seq: seq, ciphertext: ciphertext)
        compact()
    }

    fileprivate func snapshot(token: String) throws -> SyncSnapshotEnvelope? {
        _ = try authenticate(token)
        return storedSnapshot
    }

    // MARK: Внутреннее

    private func createDevice(name: String, ackSeq: Int) -> Device {
        let device = Device(id: UUID().uuidString.lowercased(), name: name, token: UUID().uuidString + UUID().uuidString,
                            lastAckSeq: ackSeq)
        devices.append(device)
        return device
    }

    private func itemsPage(after: Int) -> SyncChangesPage? {
        let newer = journal.filter { $0.seq > after }
        guard !newer.isEmpty else { return nil }
        return SyncChangesPage(items: Array(newer.prefix(200)), hasMore: newer.count > 200)
    }

    private func wake(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    /// Пачки ≤ seq снимка удаляются, когда все активные устройства подтвердили seq.
    private func compact() {
        guard let snapshot = storedSnapshot, snapshot.seq > compactedThrough else { return }
        let active = devices.filter(\.isActive)
        guard !active.isEmpty, active.allSatisfy({ $0.lastAckSeq >= snapshot.seq }) else { return }
        journal.removeAll { $0.seq <= snapshot.seq }
        compactedThrough = snapshot.seq
    }
}

private struct FakeSyncTransport: SyncTransport {
    let server: FakeSyncServer
    let token: String

    func postChanges(batchId: String, ciphertext: String) async throws -> Int {
        try await server.post(token: token, batchId: batchId, ciphertext: ciphertext)
    }

    func changes(after: Int, wait: Int) async throws -> SyncChangesPage {
        try await server.read(token: token, after: after, wait: wait)
    }

    func ack(_ seq: Int) async throws { try await server.ack(token: token, seq: seq) }

    func putSnapshot(seq: Int, ciphertext: String) async throws {
        try await server.putSnapshot(token: token, seq: seq, ciphertext: ciphertext)
    }

    func snapshot() async throws -> SyncSnapshotEnvelope? { try await server.snapshot(token: token) }

    func devices() async throws -> [SyncDevice] { try await server.listDevices(token: token) }

    func currentDevice() async throws -> SyncDevice { try await server.currentDevice(token: token) }

    func invite() async throws -> SyncInvite { try await server.invite(token: token) }

    func deleteDevice(_ deviceId: String) async throws { try await server.disable(token: token, deviceId: deviceId) }
}

/// Связь, которую тест может «выдернуть»: без связи каждый запрос падает, как без сети.
final class SwitchableTransport: SyncTransport, @unchecked Sendable {
    private let base: any SyncTransport
    private let lock = NSLock()
    private var online = true
    private var acksToLose = 0

    init(_ base: any SyncTransport) {
        self.base = base
    }

    var isOnline: Bool {
        get { lock.withLock { online } }
        set { lock.withLock { online = newValue } }
    }

    private func checkOnline() throws {
        guard isOnline else { throw URLError(.notConnectedToInternet) }
    }

    func postChanges(batchId: String, ciphertext: String) async throws -> Int {
        try checkOnline()
        return try await base.postChanges(batchId: batchId, ciphertext: ciphertext)
    }

    /// Долгое ожидание обрывается, как только связь «выдернули».
    func changes(after: Int, wait: Int) async throws -> SyncChangesPage {
        try checkOnline()
        let base = base
        return try await withThrowingTaskGroup(of: SyncChangesPage?.self) { group in
            group.addTask { try await base.changes(after: after, wait: wait) }
            group.addTask { [self] in
                while self.isOnline { try await Task.sleep(for: .milliseconds(20)) }
                throw URLError(.networkConnectionLost)
            }
            defer { group.cancelAll() }
            guard let page = try await group.next() ?? nil else { throw URLError(.networkConnectionLost) }
            try checkOnline()
            return page
        }
    }

    /// Следующие `count` подтверждений теряются по дороге, как при обрыве связи.
    func loseAcks(_ count: Int) {
        lock.withLock { acksToLose = count }
    }

    func ack(_ seq: Int) async throws {
        try checkOnline()
        let isLost = lock.withLock {
            defer { acksToLose = max(0, acksToLose - 1) }
            return acksToLose > 0
        }
        if isLost { throw URLError(.networkConnectionLost) }
        try await base.ack(seq)
    }

    func putSnapshot(seq: Int, ciphertext: String) async throws {
        try checkOnline()
        try await base.putSnapshot(seq: seq, ciphertext: ciphertext)
    }

    func snapshot() async throws -> SyncSnapshotEnvelope? {
        try checkOnline()
        return try await base.snapshot()
    }

    func devices() async throws -> [SyncDevice] {
        try checkOnline()
        return try await base.devices()
    }

    func currentDevice() async throws -> SyncDevice {
        try checkOnline()
        return try await base.currentDevice()
    }

    func invite() async throws -> SyncInvite {
        try checkOnline()
        return try await base.invite()
    }

    func deleteDevice(_ deviceId: String) async throws {
        try checkOnline()
        try await base.deleteDevice(deviceId)
    }
}
