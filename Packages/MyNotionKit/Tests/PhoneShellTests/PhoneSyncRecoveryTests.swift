import Foundation
import NotesCore
import PhoneShell
import Sync
import Testing

/// Сбои вокруг синхронизации на iPhone: закрытая связка ключей при запуске, неудачное удаление ключей,
/// фон без сети и без выданного времени, действия экранов во время другого действия.
@MainActor
@Suite("iPhone: синхронизация переживает сбои")
struct PhoneSyncRecoveryTests {
    let library: TemporaryLibrary
    let secrets = UnreliableSecrets()
    let backgroundTime = FakeBackgroundTime()
    let pauses = FakePauses()

    init() throws {
        library = try TemporaryLibrary()
    }

    func controller(server: FakeSyncServer = FakeSyncServer(), loops: LoopCounter = LoopCounter()) -> PhoneSyncController {
        PhoneSyncController(store: library.store, openDocuments: nil, deviceName: "iPhone", secrets: secrets,
                            makeServer: { _ in server }, makeLoop: { _, _, _ in loops.make() },
                            backgroundTime: backgroundTime, pause: pauses.pause)
    }

    @Test("Связка ключей не ответила при запуске: значок просит разблокировать, при возвращении цикл запускается")
    func lockedKeychainAtLaunchRecoversOnForeground() async {
        await controller().join(codeText: sampleJoinCode().text)
        secrets.loadFails = true
        let loops = LoopCounter()
        let sync = controller(loops: loops)
        #expect(sync.isEnabled)
        #expect(loops.made.isEmpty)
        #expect(sync.badge?.kind == .error)
        #expect(sync.badge?.detail == PhoneSyncMessages.secretsLocked)

        secrets.loadFails = false
        sync.didEnterBackground()
        sync.willEnterForeground()
        #expect(loops.made.count == 1)
        #expect(loops.made.first?.isRunning == true)
        #expect(sync.badge?.kind == .ready)
    }

    @Test("Ключей нет совсем: значок советует подключить заново")
    func missingSecretsAskToReconnect() async throws {
        await controller().join(codeText: sampleJoinCode().text)
        try secrets.delete(for: "phone-1")
        let sync = controller()
        #expect(sync.badge?.detail == PhoneSyncMessages.missingSecrets)
    }

    @Test("Подключение не прочиталось из базы: значок с ошибкой, а не тихо выключенная синхронизация")
    func unreadableConnectionIsShown() throws {
        try library.store.database.dbWriter.write { try $0.execute(sql: "DROP TABLE sync_account") }
        let sync = controller()
        #expect(sync.badge?.kind == .error)
        #expect(sync.badge?.detail == PhoneSyncMessages.unreadableConnection)
    }

    @Test("Ключи не стёрлись при «Выключить»: iPhone всё равно выключен, ключи стираются при следующем возвращении")
    func disableFinishesWhenSecretsStay() async throws {
        let sync = controller()
        await sync.join(codeText: sampleJoinCode().text)
        secrets.deleteFails = true
        await sync.disable()
        #expect(!sync.isEnabled)
        #expect(sync.badge == nil)
        #expect(sync.errorMessage == PhoneSyncMessages.secretsNotErased)
        #expect(try SyncAccountStore(store: library.store).account() == nil)
        #expect(try secrets.storedValues(for: "phone-1") != nil)

        secrets.deleteFails = false
        sync.didEnterBackground()
        sync.willEnterForeground()
        #expect(try secrets.storedValues(for: "phone-1") == nil)
    }

    @Test("Система не дала фонового времени: цикл останавливается сразу, без ожидания")
    func noBackgroundTimeStopsAtOnce() async {
        let loops = LoopCounter()
        let sync = controller(loops: loops)
        await sync.join(codeText: sampleJoinCode().text)
        loops.made.first?.unsentChecksLeft = nil
        backgroundTime.grants = false
        sync.didEnterBackground()
        #expect(sync.phase == .suspended)
        #expect(loops.made.first?.isRunning == false)
        #expect(pauses.elapsed == .zero)
    }

    @Test("Досылка в фоне без сети: цикл с ошибкой не держит фоновое время до предела")
    func backgroundFlushStopsOnError() async {
        let loops = LoopCounter()
        let sync = controller(loops: loops)
        await sync.join(codeText: sampleJoinCode().text)
        let loop = loops.made.first
        loop?.unsentChecksLeft = nil
        loop?.status = .error("Нет связи с сервером")
        sync.didEnterBackground()
        #expect(await eventually { sync.phase == .suspended })
        #expect(pauses.elapsed < .seconds(1))
        #expect(!backgroundTime.isHeld)
    }

    @Test("«Выключить», пока обновляется список устройств: выключение ждёт и выполняется, а не теряется")
    func disableWaitsForDeviceRefresh() async {
        let server = FakeSyncServer(holdsDevices: true)
        let sync = controller(server: server)
        await sync.join(codeText: sampleJoinCode().text)
        let refresh = Task { await sync.refreshDevices() }
        #expect(await eventually { sync.isBusy })
        let disable = Task { await sync.disable() }
        await Task.yield()
        server.releaseDevices()
        await refresh.value
        await disable.value
        #expect(!sync.isEnabled)
        #expect(server.deletedDevices == ["phone-1"])
    }
}

/// Считает циклы, которые создал контроллер.
@MainActor
final class LoopCounter {
    private(set) var made: [FakeSyncLoop] = []

    func make() -> FakeSyncLoop {
        let loop = FakeSyncLoop()
        made.append(loop)
        return loop
    }
}
