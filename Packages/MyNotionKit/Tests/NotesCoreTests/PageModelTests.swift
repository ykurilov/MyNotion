import Foundation
import Testing
@testable import NotesCore

/// Поля страницы 003 (data-model.md, «Page», «PageCover», «DateMention», «window_state»).
@Suite("Модель страницы 003")
struct PageModelTests {
    let device = UUID()
    let ref = AttachmentRef(name: "Обложка.jpg", byteCount: 1_024, contentType: "public.jpeg", sha256: String(repeating: "a", count: 64))

    private func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: PageCover

    @Test("Обложка из галереи и из файла кодируется по contracts/sync-v3-and-export.md")
    func coverEncoding() throws {
        let gallery = PageCover(source: .gallery("gradients_3"))
        #expect(gallery.offset == 0.5)
        #expect(try json(gallery) == #"{"offset":0.5,"source":{"gallery":"gradients_3"}}"#)
        let file = PageCover(source: .file(ref), offset: 0.42)
        let decoded = try JSONDecoder().decode(PageCover.self, from: Data(try json(file).utf8))
        #expect(decoded == file)
        #expect(decoded.attachment == ref)
        #expect(gallery.attachment == nil)
    }

    @Test("Сдвиг обложки урезается к 0…1 и при создании, и при чтении")
    func coverOffsetIsClamped() throws {
        #expect(PageCover(source: .gallery("solid_red"), offset: 1.7).offset == 1)
        #expect(PageCover(source: .gallery("solid_red"), offset: -0.2).offset == 0)
        let decoded = try JSONDecoder().decode(PageCover.self, from: Data(#"{"offset":3,"source":{"gallery":"solid_red"}}"#.utf8))
        #expect(decoded.offset == 1)
    }

    @Test("Неизвестный id галереи (от новой версии) сохраняется как есть")
    func unknownGalleryIdIsKept() throws {
        let decoded = try JSONDecoder().decode(PageCover.self, from: Data(#"{"offset":0.5,"source":{"gallery":"nasa_future_99"}}"#.utf8))
        #expect(decoded.source == .gallery("nasa_future_99"))
        #expect(try json(decoded).contains("nasa_future_99"))
    }

    // MARK: Поля страницы

    @Test("changedFields различает шесть новых полей")
    func changedFieldsKnowsNewFields() {
        let now = Date()
        let page = Page(title: "П", sortKey: .between(nil, nil), createdAt: now, updatedAt: now)
        var changed = page
        changed.cover = PageCover(source: .gallery("solid_blue"))
        #expect(changed.changedFields(comparedTo: page) == [.cover])
        changed = page; changed.isFullWidth = true
        #expect(changed.changedFields(comparedTo: page) == [.isFullWidth])
        changed = page; changed.isSmallText = true
        #expect(changed.changedFields(comparedTo: page) == [.isSmallText])
        changed = page; changed.favorite = .between(nil, nil)
        #expect(changed.changedFields(comparedTo: page) == [.favorite])
        changed = page; changed.visitedAt = now
        #expect(changed.changedFields(comparedTo: page) == [.visitedAt])
        changed = page; changed.isTemplate = true
        #expect(changed.changedFields(comparedTo: page) == [.isTemplate])
        #expect(Set(Page.Field.allCases).isSuperset(of: [.cover, .isFullWidth, .isSmallText, .favorite, .visitedAt, .isTemplate]))
    }

    @Test("Новая страница: обложки нет, вид обычный, не в избранном, не шаблон, не открывалась")
    func defaults() {
        let page = Page(title: "П", sortKey: .between(nil, nil), createdAt: Date(), updatedAt: Date())
        #expect(page.cover == nil && !page.isFullWidth && !page.isSmallText && page.favorite == nil && page.visitedAt == nil && !page.isTemplate)
    }

    @Test("Новые поля переживают запись и чтение; метки часов у каждого своя")
    func newFieldsRoundTrip() throws {
        let folder = try TemporaryFolder()
        let wall = AdjustableWallClock()
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: device, wallClock: wall.reading))
        let created = try store.write { try $0.createPage(title: "Поля") }
        let visit = Date(timeIntervalSince1970: 1_790_000_000.123)
        wall.set(5_000)
        let updated = try store.write { tx in
            var page = try #require(try tx.page(created.id))
            page.cover = PageCover(source: .file(ref), offset: 0.3)
            page.isFullWidth = true
            page.isSmallText = true
            page.favorite = FractionalSortKey(rawValue: "a0V")
            page.visitedAt = visit
            page.isTemplate = true
            return try tx.updatePage(page)
        }
        let read = try #require(try store.pageOutline().first { $0.id == created.id })
        #expect(read.cover == PageCover(source: .file(ref), offset: 0.3))
        #expect(read.isFullWidth && read.isSmallText && read.isTemplate)
        #expect(read.favorite?.rawValue == "a0V")
        #expect(abs((read.visitedAt ?? .distantPast).timeIntervalSince(visit)) < 0.001)
        let clocks = read.fieldClocks
        for field in [Page.Field.cover, .isFullWidth, .isSmallText, .favorite, .visitedAt, .isTemplate] {
            #expect(clocks[field] == updated.fieldClocks[field])
            #expect(clocks[field] != nil && clocks[field] != created.fieldClocks.title, "\(field): своя новая метка")
        }
        #expect(clocks.title == created.fieldClocks.title, "название не менялось — метка прежняя")
    }

    @Test("favorite и visitedAt не меняют «изменено»; обложка, вид и шаблон — меняют")
    func updatedAtRules() throws {
        let folder = try TemporaryFolder()
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: device))
        let created = try store.write { try $0.createPage(title: "Изменено") }
        func update(_ change: (inout Page) -> Void) throws -> Page {
            try store.write { tx in
                var page = try #require(try tx.page(created.id))
                page.updatedAt = Date(timeIntervalSince1970: 0)
                try tx.execute(sql: "UPDATE page SET updatedAt = ? WHERE id = ?", arguments: [.text("1970-01-01 00:00:00.000"), .text(created.id.uuidString.lowercased())])
                change(&page)
                return try tx.updatePage(page)
            }
        }
        #expect(try update { $0.favorite = .between(nil, nil) }.updatedAt.timeIntervalSince1970 == 0)
        #expect(try update { $0.visitedAt = Date() }.updatedAt.timeIntervalSince1970 == 0)
        #expect(try update { $0.favorite = nil; $0.visitedAt = nil }.updatedAt.timeIntervalSince1970 == 0)
        #expect(try update { $0.cover = PageCover(source: .gallery("solid_red")) }.updatedAt.timeIntervalSince1970 > 0)
        #expect(try update { $0.isFullWidth = true }.updatedAt.timeIntervalSince1970 > 0)
        #expect(try update { $0.isSmallText = true }.updatedAt.timeIntervalSince1970 > 0)
        #expect(try update { $0.isTemplate = true }.updatedAt.timeIntervalSince1970 > 0)
    }

    // MARK: DateMention

    @Test("Дата шаблона: templateRelative кодируется; неизвестные ключи даты сохраняются")
    func dateMentionTemplateRelative() throws {
        let id = UUID.timeOrdered()
        let date = DateMention(id: id, start: "2026-10-20", includesTime: false, timeZone: "Europe/Moscow", templateRelative: .today)
        let text = try json(date)
        #expect(text.contains(#""templateRelative":"today""#))
        #expect(try JSONDecoder().decode(DateMention.self, from: Data(text.utf8)) == date)
        #expect(!(try json(DateMention(id: id, start: "2026-10-20", includesTime: false, timeZone: "UTC"))).contains("templateRelative"))
        #expect(DateMention.TemplateRelative(rawValue: "now") == .now)

        let future = #"{"id":"\#(id.uuidString)","includesTime":true,"start":"2026-10-20T09:00","timeZone":"UTC","futureKey":{"a":1},"templateRelative":"now"}"#
        let decoded = try JSONDecoder().decode(DateMention.self, from: Data(future.utf8))
        #expect(decoded.templateRelative == .now)
        let again = try json(decoded)
        #expect(again.contains(#""futureKey":{"a":1}"#), "неизвестный ключ даты переносится при записи")
    }

    // MARK: Вкладки окна

    @Test("Вкладки окна кодируются по data-model.md: active, items; Tab — id, pageId, scroll, back, forward")
    func tabsEncoding() throws {
        let pageA = UUID.timeOrdered(), pageB = UUID.timeOrdered(), block = UUID.timeOrdered()
        let tab = Tab(id: UUID.timeOrdered(), pageId: pageA, scroll: TabScroll(blockId: block, offset: 12.5),
                      back: [TabEntry(pageId: pageB, scroll: nil)], forward: [])
        let tabs = TabsState(active: 1, items: [Tab(id: UUID.timeOrdered()), tab])
        let text = try json(tabs)
        #expect(text.hasPrefix(#"{"active":1,"items":["#))
        #expect(text.contains(#""scroll":{"blockId":"\#(block.uuidString)","offset":12.5}"#))
        #expect(text.contains(#""back":[{"pageId":"\#(pageB.uuidString)"}]"#))
        #expect(try JSONDecoder().decode(TabsState.self, from: Data(text.utf8)) == tabs)
        #expect(Tab(id: UUID()).pageId == nil, "пустая вкладка — «Новая вкладка»")
    }

    @Test("Вкладки и свёрнутые разделы панели переживают закрытие базы; пусто — одна вкладка с openPageId")
    func tabsSurviveReopen() throws {
        let folder = try TemporaryFolder()
        let pageId = UUID.timeOrdered()
        let tabs = TabsState(active: 0, items: [Tab(id: UUID.timeOrdered(), pageId: pageId, back: [TabEntry(pageId: UUID.timeOrdered())])])
        do {
            let database = try AppDatabase.open(at: folder.databaseURL)
            let store = NotesStore(database: database, clock: HybridLogicalClock(deviceId: device))
            try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: pageId))
            let plain = try #require(try store.windowState(WindowState.mainWindowId))
            #expect(plain.tabs == nil && plain.collapsedSidebarSections.isEmpty)
            try store.saveWindowState(WindowState(windowId: WindowState.mainWindowId, openPageId: pageId, tabs: tabs,
                                                  collapsedSidebarSections: [.recent, .templates]))
            database.close()
        }
        let database = try AppDatabase.open(at: folder.databaseURL)
        defer { database.close() }
        let restored = try #require(try NotesStore(database: database, clock: HybridLogicalClock(deviceId: device)).windowState(WindowState.mainWindowId))
        #expect(restored.tabs == tabs)
        #expect(restored.collapsedSidebarSections == [.recent, .templates])
    }
}
