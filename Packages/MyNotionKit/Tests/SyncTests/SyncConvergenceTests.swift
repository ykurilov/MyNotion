import Foundation
import Testing
@testable import NotesCore
@testable import Sync

/// Два и три Mac с настоящим циклом синхронизации (`SyncEngine`) через сервер: правка доходит быстро (SC-007),
/// правки без связи не теряются (SC-008), после сжатия журнала новый Mac догоняет со снимка.
@MainActor
@Suite("Сходимость через сервер", .serialized)
struct SyncConvergenceTests {
    @Test("Правка на одном Mac появляется на другом не позже чем через 10 секунд", arguments: SyncTestServerKind.available)
    func editArrivesWithinTenSeconds(_ kind: SyncTestServerKind) async throws {
        let server = try await kind.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        let started = ContinuousClock.now
        let page = try a.store.write { try $0.createPage(title: "Пишу на A") }
        try await eventually("страница дошла до B", within: .seconds(10)) {
            try b.store.pageOutline().contains { $0.id == page.id && $0.title == "Пишу на A" }
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(10), "Дошла за \(elapsed)")
        try await eventually("оба Mac отправили всё", within: .seconds(10)) { a.engine.status == .ready && b.engine.status == .ready }
    }

    @Test("Оба Mac правят без связи, связь возвращается — потеряно 0 правок", arguments: SyncTestServerKind.available)
    func offlineEditsAreNotLost(_ kind: SyncTestServerKind) async throws {
        let server = try await kind.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        let shared = try a.store.write { tx in
            let page = try tx.createPage(title: "Общая")
            var key: FractionalSortKey?
            var ids: [UUID] = []
            for text in ["один", "два", "три"] {
                key = .between(key, nil)
                ids.append(try tx.insertBlock(Block(pageId: page.id, text: InlineText(text), sortKey: key!)).id)
            }
            return (page: page.id, blocks: ids)
        }
        try await eventually("страница дошла до B", within: .seconds(10)) {
            try b.store.pageContent(shared.page)?.blocks.count == 4
        }

        a.connection.isOnline = false
        b.connection.isOnline = false
        try await eventually("оба видят, что связи нет", within: .seconds(10)) {
            a.engine.status.isError && b.engine.status.isError
        }

        try a.setText("один — правка A", ofBlock: shared.blocks[0])
        try a.setText("три — правка A", ofBlock: shared.blocks[2])
        let newOnA = try a.store.write { try $0.createPage(title: "Новая на A без связи") }
        try b.setText("два — правка B", ofBlock: shared.blocks[1])
        try b.setText("три — правка B", ofBlock: shared.blocks[2])
        let newOnB = try b.store.write { try $0.createPage(title: "Новая на B без связи") }

        a.connection.isOnline = true
        b.connection.isOnline = true
        a.engine.syncNow()
        b.engine.syncNow()

        let edits = ["один — правка A", "два — правка B", "три — правка A", "три — правка B"]
        try await eventually("правки сошлись", within: .seconds(20)) {
            try [a, b].allSatisfy { mac in
                let seen = try mac.allTextVersions(of: shared.page)
                let pageIds = try mac.store.pageOutline().map(\.id)
                return edits.allSatisfy(seen.contains) && pageIds.contains(newOnA.id) && pageIds.contains(newOnB.id)
            }
        }
        for mac in [a, b] {
            let blocks = try #require(try mac.store.pageContent(shared.page)).blocks.map(\.text.string)
            #expect(blocks.contains("один — правка A") && blocks.contains("два — правка B"), "\(mac.name): разные блоки слились")
            let conflicts = try mac.store.unresolvedConflicts(ofPage: shared.page)
            #expect(conflicts.count == 1, "\(mac.name): один блок с двух сторон — «Две версии»")
        }
    }

    @Test("Журнал сжимается после снимка, третий Mac подключается и догоняет со снимка", arguments: SyncTestServerKind.available)
    func thirdMacJoinsFromSnapshot(_ kind: SyncTestServerKind) async throws {
        let server = try await kind.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        for index in 1...5 {
            try a.store.write { tx in _ = try tx.createPage(title: "Страница \(index)") }
        }
        let fromB = try b.store.write { try $0.createPage(title: "С Mac B") }
        try await eventually("A и B сошлись", within: .seconds(10)) {
            try a.titles() == b.titles() && a.titles().count == 6
                && a.engine.status == .ready && b.engine.status == .ready
        }

        try await a.engine.uploadSnapshot()
        try await eventually("журнал сжат", within: .seconds(10)) { try await server.isCompacted() }

        let c = try EngineTestMac(name: "Mac C", wallMillis: 50_000)
        defer { c.stop() }
        try await c.join(server, code: a.makeJoinCode())
        c.start()
        try await eventually("C догнал со снимка", within: .seconds(10)) {
            try c.titles() == a.titles()
        }
        #expect(try c.store.pageOutline().contains { $0.id == fromB.id })

        let fromC = try c.store.write { try $0.createPage(title: "С Mac C") }
        try await eventually("правка C дошла до A и B", within: .seconds(10)) {
            try a.store.pageOutline().contains { $0.id == fromC.id } && b.store.pageOutline().contains { $0.id == fromC.id }
        }
    }

    @Test("Пачка более нового формата ждёт: она не применяется, Юрий видит «обновите MyNotion на этом Mac»")
    func newerFormatBatchWaits() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }
        try await eventually("оба на связи", within: .seconds(10)) { a.engine.status == .ready && b.engine.status == .ready }

        a.engine.formatVersionForTests = SyncBatch.currentFormatVersion + 1
        let page = try a.store.write { try $0.createPage(title: "Из будущего") }
        try await eventually("B сообщил об обновлении", within: .seconds(10)) {
            if case .error(let message) = b.engine.status { message.localizedCaseInsensitiveContains("обновите MyNotion") } else { false }
        }
        #expect(try !b.store.pageOutline().contains { $0.id == page.id })
        let pulledBefore = try #require(try SyncAccountStore(store: b.store).account()).lastPulledSeq
        try await Task.sleep(for: .milliseconds(300))
        #expect(try SyncAccountStore(store: b.store).account()?.lastPulledSeq == pulledBefore, "Пачка ждёт: номер не сдвинут")
    }

    @Test("Первый Mac находит себя по токену (/devices/me), даже когда на сервере уже несколько Mac; отключённый токен не принят",
          arguments: SyncTestServerKind.available)
    func firstMacIdentifiesItselfByToken(_ kind: SyncTestServerKind) async throws {
        let server = try await kind.start()
        defer { server.stop() }
        let token = try await server.bootstrapToken(name: "Mac A")
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        try await a.connectFirst(server, token: token)
        let b = try EngineTestMac(name: "Mac B", wallMillis: 10_000)
        try await b.join(server, code: a.makeJoinCode())

        // Синхронизацию на A выключили и включили снова тем же токеном: на сервере уже два устройства.
        let again = try EngineTestMac(name: "Mac A", wallMillis: 20_000)
        try await again.connectFirst(server, token: token)
        #expect(again.account.deviceId == a.account.deviceId, "Mac взял свой id, а не чужой")
        #expect(try await b.connection.devices().count == 2)

        try await b.connection.deleteDevice(a.account.deviceId)
        await #expect(throws: SyncServerError.unauthorized) { try await again.connection.currentDevice() }
    }

    @Test("Правка больше 4 МБ не держит остальные: они доходят, значок говорит о большой правке, сокращённая — доходит",
          arguments: SyncTestServerKind.available)
    func oversizedEditDoesNotBlockQueue(_ kind: SyncTestServerKind) async throws {
        let server = try await kind.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        let big = try a.store.write { try $0.createPage(title: "Огромная вставка") }
        let blockId = try #require(try a.store.pageContent(big.id)?.blocks.first).id
        try a.setText(String(repeating: "текст ", count: 600_000), ofBlock: blockId)
        let after = try a.store.write { try $0.createPage(title: "Обычная после большой") }

        try await eventually("обычная правка дошла до B", within: .seconds(20)) {
            try b.store.pageOutline().contains { $0.id == after.id }
        }
        try await eventually("A говорит о большой правке", within: .seconds(10)) {
            if case .error(let message) = a.engine.status { message.contains("Огромная вставка") } else { false }
        }

        try a.setText("коротко", ofBlock: blockId)
        try await eventually("сокращённый блок дошёл до B", within: .seconds(20)) {
            try b.store.pageContent(big.id)?.blocks.map(\.text.string) == ["коротко"]
        }
        try await eventually("A снова готов", within: .seconds(10)) { a.engine.status == .ready }
    }

    @Test("Потерянное подтверждение уходит снова и без новых правок", arguments: SyncTestServerKind.available)
    func lostAckIsRetried(_ kind: SyncTestServerKind) async throws {
        let server = try await kind.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        b.connection.loseAcks(1)
        let page = try a.store.write { try $0.createPage(title: "Подтвердить") }
        try await eventually("страница дошла до B", within: .seconds(10)) {
            try b.store.pageOutline().contains { $0.id == page.id }
        }
        let pulled = try #require(try SyncAccountStore(store: b.store).account()).lastPulledSeq
        try await eventually("сервер знает, что B всё получил", within: .seconds(10)) {
            let me = try await b.connection.currentDevice()
            return me.lastAckSeq >= pulled
        }
    }

    // MARK: Помощники

    private func connectedPair(_ server: any SyncTestServer) async throws -> (EngineTestMac, EngineTestMac) {
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        try await a.connectFirst(server)
        let b = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
        try await b.join(server, code: a.makeJoinCode())
        a.start()
        b.start()
        return (a, b)
    }
}

/// Ждать условия, проверяя его часто; без жёстких пауз.
@MainActor
func eventually(_ what: String, within limit: Duration, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    if try await condition() { return }
    Issue.record("Не дождались: \(what) за \(limit)")
    throw EventuallyTimeout()
}

struct EventuallyTimeout: Error {}

/// Сходимость возможностей 003 через настоящий цикл синхронизации двух Mac и поддельный сервер (SC-208, FR-221…): поля
/// страницы, избранное с двух Mac, перенос блоков, дублирование и шаблоны, Mac со старым форматом. Слияние по полям
/// подробно проверяют `ChangeMergerV3Tests` и `SyncPayloadV3Tests`; восстановление версии, доходящее до другого Mac
/// обычными правками, — `PageVersionsTests/VersionRestoreTests.restoreSyncs` (модуль `PageVersions` сюда не подключён).
@MainActor
@Suite("Сходимость возможностей 003 через сервер", .serialized)
struct SyncConvergenceV3Tests {
    @Test("Все новые поля страницы доходят: обложка, широкая, мелкий шрифт, избранное, шаблон, последнее открытие")
    func newPageFieldsArrive() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        let page = try a.store.write { try $0.createPage(title: "Поля 003") }
        try await eventually("страница дошла до B", within: .seconds(10)) { try b.store.pageOutline().contains { $0.id == page.id } }
        let visited = Date(timeIntervalSince1970: 1_790_000_000)
        a.wall.set(30_000)
        try a.store.write { tx in
            var changed = try #require(try tx.page(page.id))
            changed.cover = PageCover(source: .gallery("gradient_3"), offset: 0.64)
            changed.isFullWidth = true
            changed.isSmallText = true
            changed.favorite = FractionalSortKey(rawValue: "m")
            changed.visitedAt = visited
            changed.isTemplate = true
            try tx.updatePage(changed)
        }
        try await eventually("поля дошли до B", within: .seconds(10)) {
            try b.store.pageTree().page(page.id)?.isTemplate == true
        }
        let arrived = try #require(try b.store.pageTree().page(page.id))
        #expect(arrived.cover == PageCover(source: .gallery("gradient_3"), offset: 0.64))
        #expect(arrived.isFullWidth && arrived.isSmallText)
        #expect(arrived.favorite == FractionalSortKey(rawValue: "m"))
        #expect(arrived.visitedAt == visited)

        // И обратно: снять отметки на B — на A тоже сняты.
        b.wall.set(60_000)
        try b.store.write { tx in
            var changed = try #require(try tx.page(page.id))
            changed.cover = nil
            changed.isTemplate = false
            changed.favorite = nil
            try tx.updatePage(changed)
        }
        try await eventually("снятие дошло до A", within: .seconds(10)) {
            let back = try a.store.pageTree().page(page.id)
            return back?.isTemplate == false && back?.cover == nil && back?.favorite == nil
        }
    }

    @Test("Избранное переставлено на двух Mac по-разному без связи: один порядок, ни одна строка не пропала")
    func favoritesReorderedOnBothMacs() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        var key: FractionalSortKey?
        var pages: [UUID] = []
        for title in ["Один", "Два", "Три", "Четыре"] {
            key = .between(key, nil)
            let favorite = key
            pages.append(try a.store.write { tx in
                var page = try tx.createPage(title: title)
                page.favorite = favorite
                return try tx.updatePage(page).id
            })
        }
        try await eventually("избранное дошло до B", within: .seconds(10)) { try b.store.favoritePages().count == 4 }
        let keys = try pages.map { try #require(try a.store.pageTree().page($0)?.favorite) }

        a.connection.isOnline = false
        b.connection.isOnline = false
        try await eventually("оба без связи", within: .seconds(10)) { a.engine.status.isError && b.engine.status.isError }
        // A ставит «Четыре» первой, B — «Один» последней, одновременно.
        a.wall.set(50_000)
        try setFavorite(.between(nil, keys[0]), pages[3], on: a)
        b.wall.set(50_000)
        try setFavorite(.between(keys[3], nil), pages[0], on: b)
        a.connection.isOnline = true
        b.connection.isOnline = true
        a.engine.syncNow()
        b.engine.syncNow()

        try await eventually("порядок сошёлся", within: .seconds(20)) {
            let orderA = try a.store.favoritePages().map(\.id)
            return orderA == (try b.store.favoritePages().map(\.id)) && orderA.first == pages[3] && orderA.last == pages[0]
        }
        #expect(Set(try a.store.favoritePages().map(\.id)) == Set(pages), "ни одна строка не пропала")
        #expect(try b.store.favoritePages().count == 4)
    }

    @Test("Перенос блоков на другую страницу доходит: на целевой они появились, на исходной их нет, подстраница переехала")
    func movedBlocksArrive() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        let pages = try a.store.write { tx -> (source: UUID, target: UUID, subpage: UUID, moved: [UUID]) in
            let source = try tx.createPage(title: "Откуда")
            let target = try tx.createPage(title: "Куда")
            let subpage = try tx.createPage(title: "Подстраница", parentId: source.id)
            for block in try tx.blocks(ofPage: source.id) { try tx.deleteBlock(block.id) }
            var key: FractionalSortKey?
            var moved: [UUID] = []
            for (text, isMoved) in [("остаётся", false), ("уедет 1", true), ("уедет 2", true)] {
                key = .between(key, nil)
                let block = try tx.insertBlock(Block(pageId: source.id, text: InlineText(text), sortKey: key!))
                if isMoved { moved.append(block.id) }
            }
            key = .between(key, nil)
            moved.append(try tx.insertBlock(Block(pageId: source.id, kind: .pageLink, linkedPageId: subpage.id, sortKey: key!)).id)
            return (source.id, target.id, subpage.id, moved)
        }
        try await eventually("страницы дошли до B", within: .seconds(10)) {
            try b.store.pageContent(pages.source)?.blocks.count == 4 && b.store.pageContent(pages.target) != nil
        }

        try PageTreeOperations(store: a.store).moveBlocks(pages.moved, from: pages.source, to: pages.target)

        try await eventually("перенос дошёл до B", within: .seconds(10)) {
            try b.store.pageContent(pages.target)?.blocks.map(\.text.string).contains("уедет 2") == true
        }
        func texts(_ mac: EngineTestMac, _ page: UUID) throws -> [String] {
            try #require(try mac.store.pageContent(page)).blocks.filter { $0.kind != .pageLink }.map(\.text.string).filter { !$0.isEmpty }
        }
        for mac in [a, b] {
            #expect(try texts(mac, pages.source) == ["остаётся"], "\(mac.name): на старой странице перенесённых блоков нет")
            #expect(try texts(mac, pages.target) == ["уедет 1", "уедет 2"], "\(mac.name): на новой они есть")
            #expect(try mac.store.pageTree().page(pages.subpage)?.parentId == pages.target, "\(mac.name): подстраница переехала")
        }
    }

    /// «Созвон» с обложкой, широкой страницей, текстом и подстраницей «Заметки».
    private func makeMeeting(on mac: EngineTestMac) throws -> Page {
        try mac.store.write { tx -> Page in
            var page = try tx.createPage(title: "Созвон", icon: "📞")
            page.cover = PageCover(source: .gallery("gradient_3"), offset: 0.4)
            page.isFullWidth = true
            page = try tx.updatePage(page)
            var first = try #require(try tx.blocks(ofPage: page.id).first)
            first.text = InlineText("Повестка")
            try tx.updateBlock(first)
            _ = try tx.createPage(title: "Заметки", parentId: page.id)
            return page
        }
    }

    /// Страницы Mac одной строкой на страницу: название, шаблон, корень, обложка, ширина, текст блоков.
    private func summary(_ mac: EngineTestMac) throws -> [String] {
        try mac.store.pageOutline().filter { $0.trashedAt == nil }.map { page in
            let blocks = try mac.store.pageContent(page.id)?.blocks.filter { $0.kind != .pageLink }.map(\.text.string).joined(separator: "/") ?? ""
            return "\(page.title)|шаблон=\(page.isTemplate)|в корне=\(page.parentId == nil)|\(page.cover != nil)|\(page.isFullWidth)|\(blocks)"
        }.sorted()
    }

    @Test("Шаблоны сходятся: шаблон в корне, страница по шаблону, «перестать быть шаблоном»")
    func templatesConverge() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }
        let tree = PageTreeOperations(store: a.store)

        let original = try makeMeeting(on: a)
        try tree.makeTemplate(original.id)
        let fromTemplate = try tree.createPage(fromTemplate: original.id)

        try await eventually("шаблон, копия и подстраницы сошлись", within: .seconds(15)) {
            try summary(a) == summary(b) && a.store.pageOutline().count == 4 && a.engine.status == .ready && b.engine.status == .ready
        }
        let onB = try b.store.pageTree()
        #expect(onB.page(original.id)?.isTemplate == true)
        #expect(onB.page(original.id)?.parentId == nil)
        #expect(onB.page(fromTemplate.id)?.isTemplate == false)
        #expect(onB.page(fromTemplate.id)?.title == "Созвон")
        #expect(try b.store.templatePages().map(\.id) == [original.id])

        try tree.stopBeingTemplate(original.id)
        try await eventually("снятие шаблона дошло до B", within: .seconds(10)) {
            try b.store.pageTree().page(original.id)?.isTemplate == false && b.store.templatePages().isEmpty
        }
        #expect(try summary(a) == summary(b))
    }

    /// Этот тест нашёл взаимную блокировку: «Дублировать» пишет копию с очереди записи базы (`writeCopyOffMain`), а
    /// `OutboxRecorder` слал `Outbox.didEnqueue` синхронно подписчику на главной очереди, пока главная ждала запись
    /// в `Outbox.remove`. Теперь уведомление уходит на главную очередь без ожидания.
    @Test("Дублирование доходит до другого Mac: копия «(1)» с теми же блоками и подстраницей")
    func duplicateConverges() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let (a, b) = try await connectedPair(server)
        defer { a.stop(); b.stop() }

        let original = try makeMeeting(on: a)
        let copy = try await PageTreeOperations(store: a.store).duplicate(original.id)

        try await eventually("копия и подстраницы сошлись", within: .seconds(15)) {
            try summary(a) == summary(b) && a.store.pageOutline().count == 4 && a.engine.status == .ready && b.engine.status == .ready
        }
        #expect(try b.store.pageTree().page(copy.id)?.title == "Созвон (1)")
        #expect(try b.store.pageContent(copy.id)?.blocks.first?.text.string == "Повестка")
    }

    @Test("Mac со старым форматом 2 не применяет пачки v3 и показывает «Обновите MyNotion на этом Mac»; страница не появляется")
    func olderFormatMacAsksToUpdate() async throws {
        let server = try await SyncTestServerKind.fake.start()
        defer { server.stop() }
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        try await a.connectFirst(server)
        let b = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
        b.supportedFormatVersion = 2
        try await b.join(server, code: a.makeJoinCode())
        a.start()
        b.start()
        defer { a.stop(); b.stop() }

        let page = try a.store.write { try $0.createPage(title: "Шаблон из новой версии") }
        try a.store.write { tx in
            var changed = try #require(try tx.page(page.id))
            changed.isTemplate = true
            try tx.updatePage(changed)
        }
        try await eventually("B сообщил об обновлении", within: .seconds(10)) {
            if case .error(let message) = b.engine.status { message.localizedCaseInsensitiveContains("Обновите MyNotion на этом Mac") } else { false }
        }
        #expect(try !b.store.pageOutline().contains { $0.id == page.id })
        #expect(try a.store.pageTree().page(page.id)?.isTemplate == true, "У нового Mac всё на месте")
    }

    // MARK: Помощники

    private func setFavorite(_ favorite: FractionalSortKey, _ pageId: UUID, on mac: EngineTestMac) throws {
        try mac.store.write { tx in
            var page = try #require(try tx.page(pageId))
            page.favorite = favorite
            try tx.updatePage(page)
        }
    }

    private func connectedPair(_ server: any SyncTestServer) async throws -> (EngineTestMac, EngineTestMac) {
        let a = try EngineTestMac(name: "Mac A", wallMillis: 10_000)
        try await a.connectFirst(server)
        let b = try EngineTestMac(name: "Mac B", wallMillis: 20_000)
        try await b.join(server, code: a.makeJoinCode())
        a.start()
        b.start()
        return (a, b)
    }
}
