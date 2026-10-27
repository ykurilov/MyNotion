import Foundation
import NotesCore
import PhoneShell
import Sync
import Testing

/// Жизненный цикл iPhone: на переднем плане цикл работает, в фоне досылает очередь в отведённое время
/// и останавливается, при возвращении сразу просыпается.
@MainActor
@Suite("iPhone: синхронизация в фоне и на переднем плане")
struct PhoneSyncLifecycleTests {
    let library: TemporaryLibrary
    let loop = FakeSyncLoop()
    let backgroundTime = FakeBackgroundTime()
    let pauses = FakePauses()

    init() throws {
        library = try TemporaryLibrary()
    }

    func connected(flushLimit: Duration = .seconds(25), openDocuments: OpenDocuments? = nil) async -> PhoneSyncController {
        let sync = PhoneSyncController(store: library.store, openDocuments: openDocuments, deviceName: "iPhone", secrets: InMemorySyncSecrets(),
                                       makeServer: { _ in FakeSyncServer() }, makeLoop: { [loop] _, _, _ in loop },
                                       backgroundTime: backgroundTime, pause: pauses.pause, backgroundFlushLimit: flushLimit)
        await sync.join(codeText: sampleJoinCode().text)
        return sync
    }

    @Test("Уход в фон с пустой очередью: цикл останавливается сразу, фоновое время возвращается")
    func backgroundWithEmptyQueue() async {
        let sync = await connected()
        loop.unsentChecksLeft = 0
        sync.didEnterBackground()
        #expect(await eventually { sync.phase == .suspended })
        #expect(!loop.isRunning)
        #expect(backgroundTime.begun == 1)
        #expect(!backgroundTime.isHeld)
    }

    @Test("Уход в фон с очередью: цикл будится и работает, пока очередь не опустеет")
    func backgroundFlushesQueue() async {
        let sync = await connected()
        loop.unsentChecksLeft = 3
        let wakesBefore = loop.syncNowCount
        sync.didEnterBackground()
        #expect(sync.phase == .flushingInBackground)
        #expect(loop.syncNowCount == wakesBefore + 1)
        #expect(loop.isRunning)
        #expect(await eventually { sync.phase == .suspended })
        #expect(!loop.isRunning)
        #expect(pauses.elapsed > .zero)
        #expect(!backgroundTime.isHeld)
    }

    @Test("Система забрала фоновое время раньше: цикл останавливается, время возвращается")
    func backgroundTimeExpires() async {
        let sync = await connected()
        loop.unsentChecksLeft = nil
        sync.didEnterBackground()
        backgroundTime.expire()
        #expect(sync.phase == .suspended)
        #expect(!loop.isRunning)
        #expect(!backgroundTime.isHeld)
    }

    @Test("Очередь не уходит (нет сети): цикл останавливается по своему пределу")
    func backgroundFlushHasLimit() async {
        let sync = await connected(flushLimit: .seconds(5))
        loop.unsentChecksLeft = nil
        sync.didEnterBackground()
        #expect(await eventually { sync.phase == .suspended })
        #expect(!loop.isRunning)
        #expect(pauses.elapsed >= .seconds(5))
        #expect(pauses.elapsed < .seconds(6))
        #expect(!backgroundTime.isHeld)
    }

    @Test("Возвращение после остановки: цикл запускается снова и сразу будится")
    func foregroundRestartsLoop() async {
        let sync = await connected()
        sync.didEnterBackground()
        #expect(await eventually { sync.phase == .suspended })
        let starts = loop.startCount
        let wakes = loop.syncNowCount
        sync.willEnterForeground()
        #expect(sync.phase == .foreground)
        #expect(loop.isRunning)
        #expect(loop.startCount == starts + 1)
        #expect(loop.syncNowCount == wakes + 1)
    }

    @Test("Возвращение, пока очередь ещё досылается: цикл не перезапускается и не останавливается")
    func foregroundDuringFlush() async {
        let sync = await connected()
        loop.unsentChecksLeft = nil
        sync.didEnterBackground()
        let starts = loop.startCount
        sync.willEnterForeground()
        #expect(sync.phase == .foreground)
        #expect(!backgroundTime.isHeld)
        for _ in 0..<50 { await Task.yield() }
        #expect(loop.isRunning)
        #expect(loop.startCount == starts)
        #expect(sync.phase == .foreground)
    }

    @Test("Уход в фон записывает открытые страницы до отправки")
    func backgroundSavesOpenPages() async throws {
        let openDocuments = OpenDocuments(store: library.store)
        let page = try library.store.write { try $0.createPage(title: "Черновик") }
        let document = try openDocuments.open(page.id)
        let block = try #require(document.blocks.first)
        document.setText(InlineText("набрано на iPhone"), ofBlock: block.id)
        let sync = await connected(openDocuments: openDocuments)
        sync.didEnterBackground()
        #expect(try library.store.pageContent(page.id)?.blocks.first?.text.string == "набрано на iPhone")
    }

    @Test("Без подключения уход в фон и возвращение ничего не запускают")
    func lifecycleWithoutConnection() {
        let sync = PhoneSyncController(store: library.store, openDocuments: nil, deviceName: "iPhone", secrets: InMemorySyncSecrets(),
                                       makeServer: { _ in FakeSyncServer() }, makeLoop: { [loop] _, _, _ in loop },
                                       backgroundTime: backgroundTime, pause: pauses.pause)
        sync.didEnterBackground()
        sync.willEnterForeground()
        #expect(loop.startCount == 0)
        #expect(backgroundTime.begun == 0)
        #expect(sync.phase == .foreground)
    }
}
