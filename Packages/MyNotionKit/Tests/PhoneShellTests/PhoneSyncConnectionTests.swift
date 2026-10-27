import Foundation
import NotesCore
import PhoneShell
import Sync
import Testing

/// Подключение iPhone кодом с Mac: состояния, понятные ошибки, выключение.
@MainActor
@Suite("iPhone: подключение к синхронизации")
struct PhoneSyncConnectionTests {
    let library: TemporaryLibrary
    let secrets = InMemorySyncSecrets()
    var loops: [FakeSyncLoop] = []

    init() throws {
        library = try TemporaryLibrary()
    }

    func controller(server: FakeSyncServer, loop: FakeSyncLoop = FakeSyncLoop()) -> PhoneSyncController {
        PhoneSyncController(store: library.store, openDocuments: nil, deviceName: "iPhone Юрия", secrets: secrets,
                            makeServer: { _ in server }, makeLoop: { _, _, _ in loop }, backgroundTime: FakeBackgroundTime())
    }

    @Test("Без подключения синхронизация выключена, значка нет, цикл не запущен")
    func startsDisconnected() {
        let loop = FakeSyncLoop()
        let sync = controller(server: FakeSyncServer(), loop: loop)
        #expect(!sync.isEnabled)
        #expect(sync.badge == nil)
        #expect(loop.startCount == 0)
        #expect(sync.serverAddress == SyncAccount.defaultServerURL.absoluteString)
    }

    @Test("Верный код: iPhone подключается под своим именем, ключи — в связке ключей, цикл запущен")
    func joinsWithCode() async throws {
        let server = FakeSyncServer(outcome: .joined(deviceId: "phone-1"))
        let loop = FakeSyncLoop()
        let sync = controller(server: server, loop: loop)
        await sync.join(codeText: sampleJoinCode().text)
        #expect(sync.isEnabled)
        #expect(sync.errorMessage == nil)
        #expect(server.joinedNames == ["iPhone Юрия"])
        #expect(try secrets.load(for: "phone-1")?.deviceToken == "token-phone-1")
        #expect(try SyncAccountStore(store: library.store).account()?.deviceName == "iPhone Юрия")
        #expect(loop.isRunning)
    }

    @Test("Код с пробелами, переносами и строчными буквами из буфера принимается")
    func acceptsPastedCodeWithNoise() async {
        let sync = controller(server: FakeSyncServer())
        let pasted = "\n  " + sampleJoinCode().text.lowercased().replacingOccurrences(of: "-", with: " - ") + " \n"
        await sync.join(codeText: pasted)
        #expect(sync.isEnabled)
    }

    @Test("Пустой код: просьба вставить код, сервер не спрашивается")
    func emptyCode() async {
        let server = FakeSyncServer()
        let sync = controller(server: server)
        await sync.join(codeText: "  \n")
        #expect(!sync.isEnabled)
        #expect(sync.errorMessage == PhoneSyncMessages.emptyCode)
        #expect(server.joinedNames.isEmpty)
    }

    @Test("Опечатка в коде: понятная ошибка, сервер не спрашивается")
    func mistypedCode() async {
        let server = FakeSyncServer()
        let sync = controller(server: server)
        var text = Array(sampleJoinCode().text)
        text[3] = text[3] == "A" ? "B" : "A"
        await sync.join(codeText: String(text))
        #expect(!sync.isEnabled)
        #expect(sync.errorMessage == PhoneSyncMessages.mistypedCode)
        #expect(server.joinedNames.isEmpty)
    }

    @Test("Код истёк или уже использован")
    func expiredCode() async {
        let sync = controller(server: FakeSyncServer(outcome: .fails(SyncServerError.inviteExpired)))
        await sync.join(codeText: sampleJoinCode().text)
        #expect(!sync.isEnabled)
        #expect(sync.errorMessage == PhoneSyncMessages.expiredCode)
    }

    @Test("Нет сети", arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotConnectToHost, .networkConnectionLost])
    func noNetwork(code: URLError.Code) async {
        let sync = controller(server: FakeSyncServer(outcome: .fails(URLError(code))))
        await sync.join(codeText: sampleJoinCode().text)
        #expect(!sync.isEnabled)
        #expect(sync.errorMessage == PhoneSyncMessages.noNetwork)
    }

    @Test("Новая попытка стирает прежнюю ошибку")
    func retryClearsError() async {
        let server = FakeSyncServer()
        let sync = controller(server: server)
        await sync.join(codeText: "")
        #expect(sync.errorMessage != nil)
        await sync.join(codeText: sampleJoinCode().text)
        #expect(sync.errorMessage == nil)
        #expect(sync.isEnabled)
    }

    @Test("После перезапуска приложения подключение и цикл поднимаются сами")
    func resumesAfterRelaunch() async {
        let server = FakeSyncServer()
        await controller(server: server).join(codeText: sampleJoinCode().text)
        let loop = FakeSyncLoop()
        let relaunched = controller(server: server, loop: loop)
        #expect(relaunched.isEnabled)
        #expect(relaunched.account?.deviceName == "iPhone Юрия")
        #expect(loop.isRunning)
    }

    @Test("Список устройств: iPhone отмечен как «этот iPhone»")
    func listsDevices() async {
        let server = FakeSyncServer(devices: [SyncDevice(deviceId: "mac-1", deviceName: "MacBook", lastSeenAt: nil, lastAckSeq: 0),
                                              SyncDevice(deviceId: "phone-1", deviceName: "iPhone Юрия", lastSeenAt: nil, lastAckSeq: 0)])
        let sync = controller(server: server)
        await sync.join(codeText: sampleJoinCode().text)
        await sync.refreshDevices()
        #expect(sync.devices.map(\.deviceName) == ["MacBook", "iPhone Юрия"])
        #expect(sync.isThisDevice(sync.devices[1]))
        #expect(!sync.isThisDevice(sync.devices[0]))
    }

    @Test("Выключить на этом iPhone: цикл остановлен, сервер забыл iPhone, ключи стёрты, записи остались")
    func disables() async throws {
        let server = FakeSyncServer()
        let loop = FakeSyncLoop()
        let sync = controller(server: server, loop: loop)
        let page = try library.store.write { try $0.createPage(title: "Останется") }
        await sync.join(codeText: sampleJoinCode().text)
        await sync.disable()
        #expect(!sync.isEnabled)
        #expect(sync.badge == nil)
        #expect(!loop.isRunning)
        #expect(server.deletedDevices == ["phone-1"])
        #expect(try secrets.load(for: "phone-1") == nil)
        #expect(try library.store.page(page.id)?.title == "Останется")
    }

    @Test("Значок: состояние цикла словами про iPhone и время последней синхронизации")
    func badgeFollowsLoop() async {
        let loop = FakeSyncLoop()
        let sync = controller(server: FakeSyncServer(), loop: loop)
        await sync.join(codeText: sampleJoinCode().text)
        let syncedAt = Date(timeIntervalSince1970: 1_000_000)
        loop.lastSyncedAt = syncedAt
        loop.status = .ready
        #expect(sync.badge?.kind == .ready)
        #expect(sync.badge?.lastSyncedAt == syncedAt)
        loop.status = .sending
        #expect(sync.badge?.kind == .sending)
        loop.status = .error("Нет связи — правки сохранены на этом Mac и уйдут сами, когда связь вернётся")
        #expect(sync.badge?.kind == .error)
        #expect(sync.badge?.detail == "Нет связи — правки сохранены на этом iPhone и уйдут сами, когда связь вернётся")
    }
}
