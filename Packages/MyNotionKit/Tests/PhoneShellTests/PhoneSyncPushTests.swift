import Foundation
import NotesCore
import PhoneShell
import Sync
import Testing

/// Тихий пуш с сервера: iPhone в фоне просыпается, одним кругом забирает правки с Mac и честно говорит системе,
/// что вышло. Плюс токен пушей: iPhone сообщает его серверу своим токеном устройства.
@MainActor
@Suite("iPhone: тихие пуши")
struct PhoneSyncPushTests {
    let library: TemporaryLibrary
    let loop = FakeSyncLoop()
    let backgroundTime = FakeBackgroundTime()
    let pauses = FakePauses()
    let secrets = UnreliableSecrets()
    let pushServer = FakePushServer()
    let apnsToken = Data(repeating: 0x5A, count: 32)

    init() throws {
        library = try TemporaryLibrary()
    }

    func controller(wakeLimit: Duration = .seconds(25), joinOutcome: FakeSyncServer.JoinOutcome = .joined(deviceId: "phone-1")) -> PhoneSyncController {
        PhoneSyncController(store: library.store, openDocuments: nil, deviceName: "iPhone", secrets: secrets,
                            makeServer: { _ in FakeSyncServer(outcome: joinOutcome) },
                            makeLoop: { [loop] _, _, applier in
                                loop.applier = applier
                                return loop
                            },
                            makePushTransport: { [pushServer] _, deviceToken in pushServer.transport(deviceToken: deviceToken) },
                            backgroundTime: backgroundTime, pause: pauses.pause, backgroundWakeLimit: wakeLimit)
    }

    func connected(wakeLimit: Duration = .seconds(25)) async -> PhoneSyncController {
        let sync = controller(wakeLimit: wakeLimit)
        await sync.join(codeText: sampleJoinCode().text)
        return sync
    }

    /// iPhone ушёл в фон с пустой очередью и цикл остановился.
    func suspended(wakeLimit: Duration = .seconds(25)) async -> PhoneSyncController {
        let sync = await connected(wakeLimit: wakeLimit)
        loop.unsentChecksLeft = 0
        sync.didEnterBackground()
        _ = await eventually { sync.phase == .suspended }
        return sync
    }

    // MARK: Пробуждение по пушу

    @Test("Синхронизация выключена: пуш ничего не делает, «нового нет»")
    func pushWithoutConnection() async {
        let sync = controller()
        sync.didEnterBackground()
        #expect(await sync.handleBackgroundPush() == .noData)
        #expect(loop.catchUpCount == 0)
    }

    @Test("Подключение забыто: пуш ничего не делает")
    func pushAfterDisable() async {
        let sync = await suspended()
        await sync.disable()
        #expect(await sync.handleBackgroundPush() == .noData)
        #expect(loop.catchUpCount == 0)
    }

    @Test("Приложение на экране: пуш только будит работающий цикл")
    func pushInForegroundWakesLoop() async {
        let sync = await connected()
        let wakes = loop.syncNowCount
        #expect(await sync.handleBackgroundPush() == .noData)
        #expect(loop.syncNowCount == wakes + 1)
        #expect(loop.catchUpCount == 0)
    }

    @Test("В фоне пришла правка с Mac: один круг, «есть новое», экраны узнают; цикл так и остаётся остановленным")
    func pushInBackgroundCatchesUp() async {
        let sync = await suspended()
        let starts = loop.startCount
        let page = UUID()
        var touched: Set<UUID> = []
        sync.onRemoteChange = { touched.formUnion($0) }
        loop.catchUpAction = { applier in applier?.onApplied?(MergeReport(touchedPageIds: [page])) }

        #expect(await sync.handleBackgroundPush() == .newData)
        #expect(loop.catchUpCount == 1)
        #expect(sync.remoteChangeCount == 1)
        #expect(touched == [page])
        #expect(sync.phase == .suspended)
        #expect(!loop.isRunning)
        #expect(loop.startCount == starts)
    }

    @Test("Пустой и повторный пуш безвредны: «нового нет», ничего не меняется")
    func emptyAndRepeatedPushes() async {
        let sync = await suspended()
        #expect(await sync.handleBackgroundPush() == .noData)
        #expect(await sync.handleBackgroundPush() == .noData)
        #expect(loop.catchUpCount == 2)
        #expect(sync.remoteChangeCount == 0)
        #expect(!loop.isRunning)
    }

    @Test("Два пуша сразу: круг один, оба ждут его конца")
    func concurrentPushesShareOneRound() async {
        let sync = await suspended()
        let gate = AsyncGate()
        loop.catchUpAction = { applier in
            await gate.wait()
            applier?.onApplied?(MergeReport(touchedPageIds: [UUID()]))
        }
        async let first = sync.handleBackgroundPush()
        async let second = sync.handleBackgroundPush()
        #expect(await eventually { loop.catchUpCount == 1 && gate.waiters > 0 })
        gate.open()
        let results = await [first, second]
        #expect(results == [.newData, .newData])
        #expect(loop.catchUpCount == 1)
    }

    @Test("Круг не удался (нет сети): честное «не вышло», цикл не запускается")
    func failedRoundReportsFailure() async {
        let sync = await suspended()
        loop.catchUpAction = { _ in throw URLError(.notConnectedToInternet) }
        #expect(await sync.handleBackgroundPush() == .failed)
        #expect(!loop.isRunning)
        #expect(sync.phase == .suspended)
    }

    @Test("Сервер не отвечает: круг прерывается в своё время, «не вышло» — система не ждёт дольше отпущенного")
    func hangingRoundStopsAtLimit() async {
        let sync = await suspended(wakeLimit: .milliseconds(200))
        var cancelled = false
        loop.catchUpAction = { _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled = true
                throw error
            }
        }
        let started = ContinuousClock.now
        #expect(await sync.handleBackgroundPush() == .failed)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(cancelled)
    }

    @Test("Часть правок пришла, потом связь оборвалась: «есть новое»")
    func partialRoundReportsNewData() async {
        let sync = await suspended()
        loop.catchUpAction = { applier in
            applier?.onApplied?(MergeReport(touchedPageIds: [UUID()]))
            throw URLError(.networkConnectionLost)
        }
        #expect(await sync.handleBackgroundPush() == .newData)
    }

    @Test("Пуш, пока очередь досылается в фоне: досылка кончается, цикл останавливается, затем круг")
    func pushDuringBackgroundFlush() async {
        let sync = await connected()
        loop.unsentChecksLeft = nil
        sync.didEnterBackground()
        #expect(sync.phase == .flushingInBackground)
        var loopRanDuringRound = true
        loop.catchUpAction = { [loop] _ in loopRanDuringRound = loop.isRunning }

        #expect(await sync.handleBackgroundPush() == .noData)
        #expect(loop.catchUpCount == 1)
        #expect(!loopRanDuringRound)
        #expect(sync.phase == .suspended)
        #expect(!backgroundTime.isHeld)
    }

    @Test("Приложение открыли посреди круга: круг прерывается, цикл стартует после него, а не вместе")
    func foregroundDuringRound() async {
        let sync = await suspended()
        loop.catchUpAction = { _ in try await Task.sleep(for: .seconds(30)) }
        let push = Task { await sync.handleBackgroundPush() }
        #expect(await eventually { loop.isCatchingUp })

        sync.willEnterForeground()
        #expect(await push.value == .failed)
        #expect(await eventually { loop.isRunning })
        #expect(!loop.startedWhileCatchingUp)
        #expect(sync.phase == .foreground)
    }

    @Test("Система запустила приложение ради пуша: цикл не крутится, пуш — одним кругом; открыли — цикл работает")
    func launchInBackground() async {
        _ = await suspended()
        // Новый запуск того же приложения: подключение уже в базе.
        let relaunched = controller()
        relaunched.didLaunchInBackground()
        #expect(relaunched.phase == .suspended)
        #expect(!loop.isRunning)

        #expect(await relaunched.handleBackgroundPush() == .noData)
        #expect(loop.catchUpCount == 1)
        #expect(!loop.isRunning)

        relaunched.willEnterForeground()
        #expect(loop.isRunning)
    }

    @Test("Ключи не читаются (iPhone ещё не разблокировали): «не вышло»; разблокировали — следующий пуш работает")
    func pushWithLockedSecrets() async {
        _ = await suspended()
        secrets.loadFails = true
        let relaunched = controller()
        relaunched.didLaunchInBackground()
        #expect(await relaunched.handleBackgroundPush() == .failed)
        #expect(loop.catchUpCount == 0)

        secrets.loadFails = false
        #expect(await relaunched.handleBackgroundPush() == .noData)
        #expect(loop.catchUpCount == 1)
        #expect(!loop.isRunning)
    }

    // MARK: Токен пушей

    @Test("Токен пришёл до подключения: уходит на сервер сразу после него, токеном этого iPhone и со своей средой")
    func tokenBeforeJoinIsRegisteredAfter() async {
        let sync = controller()
        sync.didReceivePushToken(apnsToken, environment: .sandbox)
        #expect(pushServer.registrations.isEmpty)

        await sync.join(codeText: sampleJoinCode().text)
        #expect(await eventually { pushServer.registrations.count == 1 })
        #expect(pushServer.registrations.first == .init(deviceToken: "token-phone-1", apnsToken: apnsToken, environment: .sandbox))
    }

    @Test("Тот же токен повторно не шлётся; новый токен — шлётся")
    func sameTokenOnceNewTokenAgain() async {
        let sync = await connected()
        sync.didReceivePushToken(apnsToken, environment: .production)
        #expect(await eventually { pushServer.registrations.count == 1 })
        sync.didReceivePushToken(apnsToken, environment: .production)
        sync.willEnterForeground()
        let fresh = Data(repeating: 0x11, count: 32)
        sync.didReceivePushToken(fresh, environment: .production)
        #expect(await eventually { pushServer.registrations.count == 2 })
        #expect(pushServer.registrations.map(\.apnsToken) == [apnsToken, fresh])
    }

    @Test("Сервер не принял токен: повтор при возвращении на экран")
    func failedRegistrationRetriesOnForeground() async {
        let sync = await connected()
        pushServer.fails = true
        sync.didReceivePushToken(apnsToken, environment: .sandbox)
        for _ in 0..<50 { await Task.yield() }
        #expect(pushServer.registrations.isEmpty)

        pushServer.fails = false
        sync.didEnterBackground()
        sync.willEnterForeground()
        #expect(await eventually { pushServer.registrations.count == 1 })
    }

    @Test("Синхронизацию выключили и подключили заново: токен уходит снова — уже от нового устройства")
    func tokenRegisteredAgainAfterRejoin() async {
        let sync = await connected()
        sync.didReceivePushToken(apnsToken, environment: .sandbox)
        #expect(await eventually { pushServer.registrations.count == 1 })
        await sync.disable()
        sync.willEnterForeground()
        #expect(pushServer.registrations.count == 1)

        await sync.join(codeText: sampleJoinCode().text)
        #expect(await eventually { pushServer.registrations.count == 2 })
    }
}

/// Ворота для круга: стоит, пока тест не откроет.
@MainActor
final class AsyncGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var waiters: Int { waiting.count }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
