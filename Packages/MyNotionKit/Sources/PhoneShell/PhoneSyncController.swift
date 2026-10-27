import Foundation
import NotesCore
import Observation
import Sync

/// Синхронизация на iPhone: подключение кодом с Mac, цикл `SyncEngine` и его жизнь вместе с приложением.
/// Пока приложение на экране, цикл работает; при уходе в фон досылает очередь в отведённое системой время
/// и останавливается; при возвращении сразу просыпается. Без подключения ничего не делает — записи живут локально.
/// Файлы (вложения) на этом этапе не качаются и не отправляются: их записи приходят и уходят как обычные.
@MainActor
@Observable
public final class PhoneSyncController {
    public enum Phase: Sendable, Hashable {
        /// Приложение на экране: цикл работает.
        case foreground
        /// Приложение в фоне, очередь досылается в отведённое время.
        case flushingInBackground
        /// Приложение в фоне, цикл остановлен.
        case suspended
    }

    public typealias LoopFactory = @MainActor (SyncAccount, SyncSecretValues, RemoteChangeApplier) -> any PhoneSyncLoop

    public private(set) var account: SyncAccount?
    public private(set) var devices: [SyncDevice] = []
    public private(set) var isBusy = false
    public private(set) var phase: Phase = .foreground
    /// Сколько раз пришли правки с других устройств: экраны перечитывают дерево и открытую страницу.
    public private(set) var remoteChangeCount = 0
    /// Ошибка последнего действия на экране подключения или настроек.
    public var errorMessage: String?
    /// Адрес сервера синхронизации: тот же, что у Mac; меняет только живая проверка.
    public var serverAddress = SyncAccount.defaultServerURL.absoluteString
    /// Под этим именем iPhone виден в списке устройств на Mac.
    public var deviceName: String

    @ObservationIgnored public let store: NotesStore
    /// Страницы удалённых правок — после того, как они легли в базу и открытые страницы их приняли.
    @ObservationIgnored public var onRemoteChange: ((Set<UUID>) -> Void)?
    @ObservationIgnored private let openDocuments: OpenDocuments?
    @ObservationIgnored private let secrets: any SyncSecrets
    @ObservationIgnored private let makeServer: @Sendable (URL) -> any SyncServer
    @ObservationIgnored private let makeLoop: LoopFactory
    @ObservationIgnored private let backgroundTime: any BackgroundTimeGrant
    @ObservationIgnored private let pause: @Sendable (Duration) async -> Void
    @ObservationIgnored private let backgroundFlushLimit: Duration
    @ObservationIgnored private var backgroundGrant: BackgroundTimeToken?
    @ObservationIgnored private var backgroundFlush: Task<Void, Never>?
    private var loop: (any PhoneSyncLoop)?

    /// Шаг проверки очереди, пока она досылается в фоне.
    static let flushCheckInterval: Duration = .milliseconds(250)

    public init(store: NotesStore, openDocuments: OpenDocuments?, deviceName: String, secrets: any SyncSecrets,
                makeServer: @escaping @Sendable (URL) -> any SyncServer = { HTTPSyncServer(url: $0) },
                makeLoop: @escaping LoopFactory = PhoneSyncController.engineLoop,
                backgroundTime: any BackgroundTimeGrant = NoBackgroundTime(),
                pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                backgroundFlushLimit: Duration = .seconds(25)) {
        self.store = store
        self.openDocuments = openDocuments
        self.deviceName = deviceName
        self.secrets = secrets
        self.makeServer = makeServer
        self.makeLoop = makeLoop
        self.backgroundTime = backgroundTime
        self.pause = pause
        self.backgroundFlushLimit = backgroundFlushLimit
        // Очередь исходящих подписывается на записи один раз; пока синхронизация выключена, она ничего не пишет.
        Outbox.install(on: store)
        account = try? SyncSetup.resume(store: store)
        if let account {
            serverAddress = account.serverURL.absoluteString
            self.deviceName = account.deviceName
            startLoop(for: account)
        }
    }

    /// Настоящий цикл: `SyncEngine` против сервера из подключения.
    public static func engineLoop(account: SyncAccount, secret: SyncSecretValues, applier: RemoteChangeApplier) -> any PhoneSyncLoop {
        SyncEngine(store: applier.store, account: account,
                   transport: HTTPSyncServer(url: account.serverURL).transport(deviceToken: secret.deviceToken),
                   cipher: BatchCipher(key: secret.encryptionKey), applier: applier)
    }

    public var isEnabled: Bool { account != nil }

    /// Значок состояния; `nil` — синхронизация выключена.
    public var badge: PhoneSyncBadge? {
        guard account != nil else { return nil }
        guard let loop else { return PhoneSyncBadge(kind: .error, detail: PhoneSyncMessages.missingSecrets) }
        switch loop.status {
        case .ready:
            return PhoneSyncBadge(kind: .ready, detail: "На этом iPhone и ваших Mac одни и те же записи.", lastSyncedAt: loop.lastSyncedAt)
        case .sending:
            return PhoneSyncBadge(kind: .sending, detail: "Свежие правки уходят на ваши Mac.", lastSyncedAt: loop.lastSyncedAt)
        case .error(let message):
            return PhoneSyncBadge(kind: .error, detail: PhoneSyncMessages.onPhone(message), lastSyncedAt: loop.lastSyncedAt)
        }
    }

    public func isThisDevice(_ device: SyncDevice) -> Bool {
        device.deviceId == account?.deviceId
    }

    // MARK: Подключение

    /// Код с экрана Mac («Добавить Mac или iPhone»): набранный руками или вставленный из буфера.
    public func join(codeText: String) async {
        await perform {
            guard !codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.errorMessage = PhoneSyncMessages.emptyCode
                return
            }
            let code = try JoinCode(parsing: codeText)
            let url = try self.serverURL()
            let name = self.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = try await SyncSetup.join(store: self.store, serverURL: url, code: code, deviceName: name.isEmpty ? "iPhone" : name,
                                                   secrets: self.secrets, server: self.makeServer(url))
            self.account = account
            self.deviceName = account.deviceName
            self.startLoop(for: account)
        }
    }

    public func refreshDevices() async {
        await perform {
            guard let transport = try self.transport() else { return }
            self.devices = try await transport.devices()
        }
    }

    /// Выключить синхронизацию на этом iPhone: записи остаются, подключение, очередь и ключи удаляются.
    public func disable() async {
        await perform {
            if let account = self.account, let transport = try? self.transport() {
                // Сервер больше не ждёт этот iPhone для сжатия журнала; без связи — не страшно.
                try? await transport.deleteDevice(account.deviceId)
            }
            self.stopLoop()
            try SyncSetup.disable(store: self.store, secrets: self.secrets)
            self.account = nil
            self.devices = []
        }
    }

    public func syncNow() {
        loop?.syncNow()
    }

    // MARK: Жизненный цикл приложения

    /// Приложение ушло с экрана: открытые страницы записываются, очередь досылается, пока система даёт время.
    public func didEnterBackground() {
        openDocuments?.saveAll()
        guard phase == .foreground else { return }
        guard let loop else {
            phase = .suspended
            return
        }
        phase = .flushingInBackground
        backgroundGrant = backgroundTime.begin { [weak self] in self?.finishBackgroundFlush() }
        loop.syncNow()
        let pause = pause
        let limit = backgroundFlushLimit
        backgroundFlush = Task { [weak self] in
            var waited: Duration = .zero
            while !Task.isCancelled, waited < limit, let self, self.phase == .flushingInBackground, self.loop?.hasUnsentChanges() == true {
                await pause(Self.flushCheckInterval)
                waited += Self.flushCheckInterval
            }
            guard !Task.isCancelled else { return }
            self?.finishBackgroundFlush()
        }
    }

    /// Приложение снова на экране: остановленный цикл запускается, работающий — будится.
    public func willEnterForeground() {
        let previous = phase
        phase = .foreground
        backgroundFlush?.cancel()
        backgroundFlush = nil
        returnBackgroundTime()
        guard let loop else { return }
        if previous == .suspended { loop.start() }
        loop.syncNow()
    }

    private func finishBackgroundFlush() {
        guard phase == .flushingInBackground else { return }
        backgroundFlush?.cancel()
        backgroundFlush = nil
        loop?.stop()
        phase = .suspended
        returnBackgroundTime()
    }

    private func returnBackgroundTime() {
        guard let grant = backgroundGrant else { return }
        backgroundGrant = nil
        backgroundTime.end(grant)
    }

    // MARK: Внутреннее

    private func startLoop(for account: SyncAccount) {
        guard loop == nil else { return }
        guard let secret = try? secrets.load(for: account.deviceId) else {
            errorMessage = PhoneSyncMessages.missingSecrets
            return
        }
        let applier = RemoteChangeApplier(store: store, openDocuments: openDocuments, localDeviceName: account.deviceName)
        applier.onApplied = { [weak self] report in
            guard let self else { return }
            self.remoteChangeCount += 1
            self.onRemoteChange?(report.touchedPageIds)
        }
        let loop = makeLoop(account, secret, applier)
        self.loop = loop
        if phase == .foreground { loop.start() }
    }

    private func stopLoop() {
        backgroundFlush?.cancel()
        backgroundFlush = nil
        loop?.stop()
        loop = nil
        returnBackgroundTime()
    }

    private func serverURL() throws -> URL {
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), let scheme = url.scheme, ["https", "http"].contains(scheme), url.host != nil else {
            throw URLError(.badURL)
        }
        return url
    }

    private func transport() throws -> (any SyncTransport)? {
        guard let account else { return nil }
        guard let secret = try secrets.load(for: account.deviceId) else { throw SyncSetupError.missingSecrets }
        return makeServer(account.serverURL).transport(deviceToken: secret.deviceToken)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await action()
        } catch {
            errorMessage = PhoneSyncMessages.message(for: error)
        }
    }
}
