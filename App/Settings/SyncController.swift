import AppKit
import Attachments
import Foundation
import NotesCore
import Observation
import PageTree
import Sync

/// Синхронизация в приложении (US5): подключение Mac, цикл `SyncEngine`, значок и уведомления.
/// Пока синхронизация не включена, ничего не делает — ядро работает как прежде (FR-024).
@MainActor
@Observable
final class SyncController {
    private(set) var account: SyncAccount?
    private(set) var engine: SyncEngine?
    private(set) var devices: [SyncDevice] = []
    /// Код для «Добавить Mac или iPhone» и до какого времени он действует.
    private(set) var joinCode: JoinCode?
    private(set) var joinCodeExpiresAt: Date?
    private(set) var isBusy = false
    /// Ошибка последнего действия в настройках.
    var errorMessage: String?
    var serverAddress = SyncAccount.defaultServerURL.absoluteString
    var deviceName = Host.current().localizedName ?? "Mac"
    /// Что Юрий должен узнать: страница вернулась из корзины, «Две версии» и т. п.
    private(set) var notices: [SyncNotice] = []
    /// Состояние для галереи вместо настоящего цикла.
    var previewBadge: SyncBadgeState?
    /// Сообщение очереди файлов: «Кончилось место для файлов, общих для ваших Mac — новые файлы пока ждут на этом Mac».
    private(set) var fileNotice: String?
    /// Место файлов на сервере (`GET /files/usage`) — для настроек.
    private(set) var serverFilesUsage: SyncFilesUsage?
    /// Растёт, когда ключ DeepSeek или Notion пришёл с другого устройства: настройкам перечитать, есть ли ключ.
    private(set) var serviceKeysRevision = 0

    @ObservationIgnored let store: NotesStore
    @ObservationIgnored let attachments: AttachmentStore?
    /// Отправка и докачка файлов рядом с циклом синхронизации.
    @ObservationIgnored private var fileWork: AttachmentSyncWork?
    @ObservationIgnored private let openDocuments: OpenDocuments
    @ObservationIgnored private let secrets: any SyncSecrets
    /// Ключи DeepSeek, Notion и OpenRouter: ввод в настройках и пришедшие с других устройств.
    @ObservationIgnored let serviceKeys: ServiceKeySync
    @ObservationIgnored private var serviceKeysObserver: (any NSObjectProtocol)?
    /// Пришедшие правки легли в базу: окну перечитать дерево.
    @ObservationIgnored var onRemoteChange: ((MergeReport) -> Void)?

    init(store: NotesStore, openDocuments: OpenDocuments, attachments: AttachmentStore? = nil, secrets: any SyncSecrets = SyncKeychain(),
         startsEngine: Bool = true) {
        self.store = store
        self.attachments = attachments
        self.openDocuments = openDocuments
        self.secrets = secrets
        serviceKeys = ServiceKeySync(store: store, keys: KeychainServiceKeys(deepSeek: AppProofreading.keychain, notion: AppNotion.keychain,
                                                                                openRouter: AppAIChat.openRouterKeychain))
        serviceKeysObserver = NotificationCenter.default.addObserver(forName: ServiceKeySync.didWriteKeys, object: nil,
                                                                     queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.serviceKeysRevision += 1 }
        }
        account = try? SyncSetup.resume(store: store)
        if let account {
            serverAddress = account.serverURL.absoluteString
            deviceName = account.deviceName
            if startsEngine { startEngine(for: account) }
        }
    }

    var isEnabled: Bool { account != nil }

    /// Значок внизу боковой панели; `nil` — синхронизация выключена.
    var badge: SyncBadgeState? {
        if let previewBadge { return previewBadge }
        guard let engine else { return nil }
        if let fileNotice, !engine.status.isError {
            return SyncBadgeState(kind: .error, detail: fileNotice, lastSyncedAt: engine.lastSyncedAt)
        }
        switch engine.status {
        case .ready:
            return SyncBadgeState(kind: .ready, detail: "На всех ваших Mac одни и те же записи.", lastSyncedAt: engine.lastSyncedAt)
        case .sending:
            return SyncBadgeState(kind: .sending, detail: "Свежие правки уходят на другие Mac.", lastSyncedAt: engine.lastSyncedAt)
        case .error(let message):
            return SyncBadgeState(kind: .error, detail: message, lastSyncedAt: engine.lastSyncedAt)
        }
    }

    // MARK: Подключение

    /// Первый Mac: файл-ключ, выданный при установке (`mynotion-sync bootstrap`); адрес в файле — главнее.
    func connectFirstDevice(keyFile: URL) async {
        do {
            guard let key = FirstMacKey(fileText: try String(contentsOf: keyFile, encoding: .utf8)) else {
                errorMessage = SyncSettingsError.notAKeyFile.localizedDescription
                return
            }
            if let url = key.serverURL { serverAddress = url.absoluteString }
            await connectFirstDevice(token: key.secret)
        } catch {
            errorMessage = SyncSettingsError.notAKeyFile.localizedDescription
        }
    }

    func connectFirstDevice(token: String) async {
        await perform {
            let server = try self.server()
            let account = try await SyncSetup.connectFirstDevice(
                store: self.store, serverURL: server.url, deviceToken: token.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceName: self.deviceName, secrets: self.secrets, server: server)
            self.didConnect(account)
        }
    }

    /// Второй и следующие Mac: код с экрана уже подключённого.
    func join(codeText: String) async {
        await perform {
            let code = try JoinCode(parsing: codeText)
            let server = try self.server()
            let account = try await SyncSetup.join(store: self.store, serverURL: server.url, code: code,
                                                   deviceName: self.deviceName, secrets: self.secrets, server: server)
            self.didConnect(account)
        }
    }

    /// «Добавить Mac или iPhone»: одноразовый код на 15 минут.
    func makeJoinCode() async {
        await perform {
            guard let account = self.account, let transport = try await self.transport() else { return }
            let invite = try await transport.invite()
            guard let key = try await self.loadSecrets(for: account.deviceId)?.encryptionKey else { throw SyncSetupError.missingSecrets }
            self.joinCode = JoinCode(inviteCode: invite.inviteCode, encryptionKey: key)
            self.joinCodeExpiresAt = invite.expiresAt
        }
    }

    func hideJoinCode() {
        joinCode = nil
        joinCodeExpiresAt = nil
    }

    func refreshDevices() async {
        await perform {
            guard let transport = try await self.transport() else { return }
            self.devices = try await transport.devices()
        }
    }

    /// Отключить другой Mac (потерянный): его токен больше не действует.
    func disconnect(_ device: SyncDevice) async {
        await perform {
            guard let transport = try await self.transport() else { return }
            try await transport.deleteDevice(device.deviceId)
            self.devices = try await transport.devices()
        }
    }

    /// Выключить синхронизацию на этом Mac: записи остаются, подключение и очередь удаляются.
    func disable() async {
        await perform {
            if let account = self.account, let transport = try? await self.transport() {
                // Сервер больше не ждёт этот Mac для сжатия журнала; без связи — не страшно.
                try? await transport.deleteDevice(account.deviceId)
            }
            self.engine?.stop()
            self.engine = nil
            self.fileWork = nil
            AttachmentQueueSignal.handler = nil
            self.fileNotice = nil
            try SyncSetup.disable(store: self.store, secrets: self.secrets)
            self.account = nil
            self.devices = []
            self.hideJoinCode()
        }
    }

    func syncNow() {
        engine?.syncNow()
    }

    /// Ключ DeepSeek или Notion из настроек (`ServiceKeyName`); пустая строка удаляет. Уходит на другие устройства.
    func saveServiceKey(_ value: String, for name: String) async throws {
        try await serviceKeys.save(value, for: name)
    }

    /// Адрес сервера и ключ этого Mac — для ссылок на страницы (006); `nil` — синхронизация выключена.
    func shareConnection() -> (serverURL: URL, deviceToken: String)? {
        guard let account, let secret = try? secrets.load(for: account.deviceId) else { return nil }
        return (account.serverURL, secret.deviceToken)
    }

    /// Открытая страница: её файлы — первыми в очереди скачивания (FR-120).
    func prioritizeFiles(onPage pageId: UUID) {
        guard let fileWork, (try? attachments?.attachmentIds(onPage: pageId).isEmpty) == false else { return }
        fileWork.prioritize(pageId: pageId)
        engine?.syncNow()
    }

    /// Сколько места занимают файлы на этом Mac.
    var localFilesUsage: (bytes: Int, files: Int)? {
        try? attachments?.localUsage()
    }

    func refreshFilesUsage() async {
        guard let account, let secret = try? await loadSecrets(for: account.deviceId) else { return }
        serverFilesUsage = try? await HTTPSyncServer(url: account.serverURL).fileTransport(deviceToken: secret.deviceToken).filesUsage()
    }

    func dismissNotice() {
        if !notices.isEmpty { notices.removeFirst() }
    }

    /// Настройки подключённого Mac для галереи: без сервера и связки ключей.
    func showPreview(account: SyncAccount, joinCode: JoinCode, expiresAt: Date, devices: [SyncDevice]) {
        self.account = account
        self.joinCode = joinCode
        joinCodeExpiresAt = expiresAt
        self.devices = devices
        previewBadge = SyncBadgeState(kind: .ready, detail: "")
    }

    /// Уведомление для галереи.
    func showPreviewNotice(_ notice: SyncNotice) {
        notices = [notice]
    }

    func clearNotices() {
        notices = []
    }

    // MARK: Внутреннее

    private func didConnect(_ account: SyncAccount) {
        self.account = account
        startEngine(for: account)
    }

    /// Секреты читаются в фоне: окно и сервер команд поднимаются, даже пока macOS спрашивает доступ к связке ключей,
    /// а синхронизация стартует, когда ключ получен.
    private func startEngine(for account: SyncAccount) {
        Task { [weak self] in
            let secret = try? await self?.loadSecrets(for: account.deviceId)
            guard let self, self.account?.deviceId == account.deviceId, self.engine == nil else { return }
            guard let secret else {
                self.errorMessage = SyncSetupError.missingSecrets.localizedDescription
                return
            }
            self.startEngine(for: account, secret: secret)
        }
    }

    private func startEngine(for account: SyncAccount, secret: SyncSecretValues) {
        let applier = RemoteChangeApplier(store: store, openDocuments: openDocuments, localDeviceName: account.deviceName,
                                          serviceKeys: serviceKeys)
        applier.onApplied = { [weak self] report in
            self?.notices += report.notices.filter { notice in
                if case .textConflict = notice { false } else { true }
            }
            self?.onRemoteChange?(report)
        }
        let engine = SyncEngine(store: store, account: account,
                                transport: HTTPSyncServer(url: account.serverURL).transport(deviceToken: secret.deviceToken),
                                cipher: BatchCipher(key: secret.encryptionKey), applier: applier)
        if let attachments {
            let work = AttachmentSyncWork(attachments: attachments,
                                          transport: HTTPSyncServer(url: account.serverURL).fileTransport(deviceToken: secret.deviceToken),
                                          cipher: FileCipher(syncKey: secret.encryptionKey))
            Task { [weak self] in
                await work.transfer.setNoticeHandler { notice in Task { @MainActor in self?.fileNotice = notice } }
            }
            engine.fileWork = work
            fileWork = work
            AttachmentQueueSignal.handler = { [weak self] in
                self?.fileWork?.wake()
                self?.engine?.syncNow()
            }
        }
        self.engine = engine
        engine.start()
    }

    private func server() throws -> HTTPSyncServer {
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), let scheme = url.scheme, ["https", "http"].contains(scheme), url.host != nil else {
            throw SyncSettingsError.badServerAddress
        }
        return HTTPSyncServer(url: url)
    }

    private func transport() async throws -> (any SyncTransport)? {
        guard let account, let secret = try await loadSecrets(for: account.deviceId) else { return nil }
        return HTTPSyncServer(url: account.serverURL).transport(deviceToken: secret.deviceToken)
    }

    /// Чтение связки ключей не на главном потоке: вопрос macOS о доступе не останавливает окно.
    private func loadSecrets(for deviceId: String) async throws -> SyncSecretValues? {
        let secrets = secrets
        return try await Task.detached(priority: .userInitiated) { try secrets.load(for: deviceId) }.value
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await action()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? SyncEngine.message(for: error)
        }
    }
}

enum SyncSettingsError: LocalizedError {
    case badServerAddress
    case notAKeyFile

    var errorDescription: String? {
        switch self {
        case .badServerAddress: "В файле-ключе неверный адрес — попросите новый файл у того, кто настраивал MyNotion"
        case .notAKeyFile: "Это не файл-ключ MyNotion — выберите файл «mynotion-sync-device.env»"
        }
    }
}
