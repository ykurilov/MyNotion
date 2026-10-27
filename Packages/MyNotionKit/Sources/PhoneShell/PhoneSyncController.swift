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

    /// Что ответить системе на тихий пуш (на iPhone — `UIBackgroundFetchResult`).
    public enum BackgroundWakeResult: Sendable, Hashable {
        case newData
        case noData
        case failed
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
    @ObservationIgnored private let makePushTransport: @Sendable (URL, String) -> any SyncPushTransport
    @ObservationIgnored private let backgroundWakeLimit: Duration
    /// Круг по тихому пушу, пока приложение в фоне; второй пуш ждёт этот же круг.
    @ObservationIgnored private var pushRound: Task<Void, any Error>?
    /// Токен пушей от системы и тот, что сервер уже принял от этого устройства.
    @ObservationIgnored private var pushToken: PushTokenRegistration.Token?
    @ObservationIgnored private var registeredPushToken: PushTokenRegistration?
    @ObservationIgnored private var pushTokenRequest: Task<Void, Never>?
    @ObservationIgnored private var backgroundGrant: BackgroundTimeToken?
    @ObservationIgnored private var backgroundFlush: Task<Void, Never>?
    /// Действия экранов (подключить, выключить, список устройств) идут по одному, ни одно не теряется.
    @ObservationIgnored private var lastAction: Task<Void, Never>?
    /// Устройство, чьи токен и ключ не стёрлись при выключении: стереть при следующей возможности.
    @ObservationIgnored private var secretsToErase: String?
    private var loop: (any PhoneSyncLoop)?
    /// Почему цикл не идёт при подключении: ключи не прочитались, их нет, подключение не прочиталось из базы.
    private var startProblem: String?

    /// Шаг проверки очереди, пока она досылается в фоне.
    static let flushCheckInterval: Duration = .milliseconds(250)

    public init(store: NotesStore, openDocuments: OpenDocuments?, deviceName: String, secrets: any SyncSecrets,
                makeServer: @escaping @Sendable (URL) -> any SyncServer = { HTTPSyncServer(url: $0) },
                makeLoop: @escaping LoopFactory = PhoneSyncController.engineLoop,
                makePushTransport: @escaping @Sendable (URL, String) -> any SyncPushTransport = { HTTPSyncServer(url: $0).pushTransport(deviceToken: $1) },
                backgroundTime: any BackgroundTimeGrant = NoBackgroundTime(),
                pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                backgroundFlushLimit: Duration = .seconds(25),
                backgroundWakeLimit: Duration = .seconds(25)) {
        self.store = store
        self.openDocuments = openDocuments
        self.deviceName = deviceName
        self.secrets = secrets
        self.makeServer = makeServer
        self.makeLoop = makeLoop
        self.backgroundTime = backgroundTime
        self.pause = pause
        self.backgroundFlushLimit = backgroundFlushLimit
        self.makePushTransport = makePushTransport
        self.backgroundWakeLimit = backgroundWakeLimit
        // Очередь исходящих подписывается на записи один раз; пока синхронизация выключена, она ничего не пишет.
        Outbox.install(on: store)
        do {
            account = try SyncSetup.resume(store: store)
        } catch {
            startProblem = PhoneSyncMessages.unreadableConnection
        }
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
        if account == nil, let startProblem { return PhoneSyncBadge(kind: .error, detail: startProblem) }
        guard account != nil else { return nil }
        guard let loop else { return PhoneSyncBadge(kind: .error, detail: startProblem ?? PhoneSyncMessages.missingSecrets) }
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
            self.eraseLeftoverSecrets()
            let name = self.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let account = try await SyncSetup.join(store: self.store, serverURL: url, code: code, deviceName: name.isEmpty ? "iPhone" : name,
                                                   secrets: self.secrets, server: self.makeServer(url))
            self.account = account
            self.deviceName = account.deviceName
            self.startLoop(for: account)
            self.registerPushTokenIfNeeded()
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
            // Сервер стёр токен вместе с устройством; новое подключение сообщит его заново.
            self.pushTokenRequest?.cancel()
            self.pushTokenRequest = nil
            self.registeredPushToken = nil
            do {
                try SyncSetup.disable(store: self.store, secrets: self.secrets)
            } catch {
                // Подключение из базы уже стёрто — iPhone выключен; не стёрлись только токен и ключ: добить позже.
                guard (try? SyncAccountStore(store: self.store).account()) == nil else { throw error }
                if let account = self.account, (try? self.secrets.delete(for: account.deviceId)) == nil {
                    self.secretsToErase = account.deviceId
                }
            }
            self.account = nil
            self.startProblem = nil
            self.devices = []
            if self.secretsToErase != nil { self.errorMessage = PhoneSyncMessages.secretsNotErased }
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
        // Система времени не дала — приложение вот-вот замрёт: остановиться сразу, очередь уйдёт при возвращении.
        guard backgroundGrant != nil else { return finishBackgroundFlush() }
        loop.syncNow()
        let pause = pause
        let limit = backgroundFlushLimit
        backgroundFlush = Task { [weak self] in
            var waited: Duration = .zero
            // Без сети или при отказе сервера ждать нечего: фоновое время возвращается сразу.
            while !Task.isCancelled, waited < limit, let self, self.phase == .flushingInBackground,
                  self.loop?.hasUnsentChanges() == true, self.loop?.status.isError == false {
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
        eraseLeftoverSecrets()
        registerPushTokenIfNeeded()
        guard let loop else {
            // Цикл не запустился (например, при запуске до первой разблокировки ключи не читались) — ещё раз.
            if let account { startLoop(for: account) }
            return
        }
        if previous == .suspended, let round = pushRound {
            // Идёт круг по пушу: прервать и запустить цикл после него, чтобы они не слали одно и то же вдвоём.
            round.cancel()
            Task { [weak self] in
                _ = await round.result
                guard let self, self.phase == .foreground, self.loop === loop else { return }
                loop.start()
                loop.syncNow()
            }
            return
        }
        if previous == .suspended { loop.start() }
        loop.syncNow()
    }

    /// Система запустила приложение в фоне (тихий пуш, приложения не было в памяти): цикл не крутить,
    /// правки заберёт круг по пушу; цикл запустится, когда приложение откроют.
    public func didLaunchInBackground() {
        guard phase == .foreground else { return }
        loop?.stop()
        phase = .suspended
    }

    // MARK: Тихие пуши

    /// Тихий пуш: на другом устройстве новая пачка. На экране — разбудить цикл; в фоне — один круг
    /// в отпущенное системой время и честный итог. Повторный и пустой пуш безвредны.
    public func handleBackgroundPush() async -> BackgroundWakeResult {
        if phase == .flushingInBackground { finishBackgroundFlush() }
        // Ключи не читались при запуске (iPhone ещё не разблокировали) — может, уже читаются.
        if loop == nil, let account { startLoop(for: account) }
        guard let loop else { return account == nil ? .noData : .failed }
        guard phase == .suspended else {
            loop.syncNow()
            return .noData
        }
        let changesBefore = remoteChangeCount
        let round = pushRound ?? Task { try await loop.catchUp() }
        pushRound = round
        let limit = backgroundWakeLimit
        // Система ждёт около 30 секунд и потом гасит приложение: свой круг кончается раньше.
        let deadline = Task {
            try await Task.sleep(for: limit)
            round.cancel()
        }
        let outcome = await round.result
        deadline.cancel()
        if pushRound == round { pushRound = nil }
        if remoteChangeCount > changesBefore { return .newData }
        if case .success = outcome { return .noData }
        return .failed
    }

    /// Токен тихих пушей от системы: сервер узнаёт его от этого iPhone (если синхронизация включена).
    /// `environment` — среда Apple: отладочная сборка или TestFlight и App Store.
    public func didReceivePushToken(_ token: Data, environment: SyncPushEnvironment) {
        pushToken = PushTokenRegistration.Token(value: token, environment: environment)
        registerPushTokenIfNeeded()
    }

    /// Не принятый сервером токен сообщается снова при следующем случае: подключение, возвращение на экран.
    private func registerPushTokenIfNeeded() {
        guard pushTokenRequest == nil, let pushToken, let account else { return }
        let wanted = PushTokenRegistration(deviceId: account.deviceId, token: pushToken)
        guard registeredPushToken != wanted, let secret = try? secrets.load(for: account.deviceId) else { return }
        let transport = makePushTransport(account.serverURL, secret.deviceToken)
        pushTokenRequest = Task { [weak self] in
            let accepted = (try? await transport.registerPushToken(pushToken.value, environment: pushToken.environment)) != nil
            guard let self, !Task.isCancelled else { return }
            self.pushTokenRequest = nil
            if accepted { self.registeredPushToken = wanted }
            // Пока шёл запрос, пришёл новый токен: сообщить и его.
            if self.pushToken != pushToken || self.account?.deviceId != wanted.deviceId { self.registerPushTokenIfNeeded() }
        }
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
        let stored: SyncSecretValues?
        do {
            stored = try secrets.load(for: account.deviceId)
        } catch {
            // Хранилище не ответило (iPhone ещё не разблокировали после включения) — ключи на месте, ждём возвращения.
            startProblem = PhoneSyncMessages.secretsLocked
            return
        }
        guard let secret = stored else {
            startProblem = PhoneSyncMessages.missingSecrets
            return
        }
        startProblem = nil
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
        pushRound?.cancel()
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

    private func eraseLeftoverSecrets() {
        guard let deviceId = secretsToErase, (try? secrets.delete(for: deviceId)) != nil else { return }
        secretsToErase = nil
    }

    /// Действие ждёт конца предыдущего: «Выключить» во время обновления списка устройств не теряется.
    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        let previous = lastAction
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            self.isBusy = true
            self.errorMessage = nil
            do {
                try await action()
            } catch {
                self.errorMessage = PhoneSyncMessages.message(for: error)
            }
            self.isBusy = false
        }
        lastAction = task
        await task.value
    }
}

/// Токен пушей, который сервер принял от устройства.
private struct PushTokenRegistration: Equatable {
    struct Token: Equatable {
        let value: Data
        let environment: SyncPushEnvironment
    }

    let deviceId: String
    let token: Token
}
