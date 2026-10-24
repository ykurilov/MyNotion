import Attachments
import Foundation
import GRDB
import Testing
@testable import NotesCore
@testable import Sync

/// Слияние полей страницы 003 (research R3): «позднее побеждает» у каждого поля; избранное с двух Mac сходится
/// к одному порядку; обложка-файл с другого Mac встаёт в очередь докачки 002; снимок v3 несёт новые поля.
@MainActor
@Suite("Слияние правок v3")
struct ChangeMergerV3Tests {
    let numbering = TestJournalNumbering()
    let a: SyncTestMac
    let b: SyncTestMac

    init() throws {
        a = try SyncTestMac(name: "Mac A", wallMillis: 10_000)
        b = try SyncTestMac(name: "Mac B", wallMillis: 10_000)
    }

    private func update(_ mac: SyncTestMac, _ pageId: UUID, _ change: (inout Page) -> Void) throws {
        try mac.store.write { tx in
            var page = try #require(try tx.page(pageId))
            change(&page)
            try tx.updatePage(page)
        }
    }

    @Test("Каждое новое поле: позднее побеждает, у каждого своя метка")
    func laterFieldWins() throws {
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        a.wall.set(30_000)
        try update(a, shared.page) {
            $0.cover = PageCover(source: .gallery("solid_red"))
            $0.isFullWidth = true
            $0.favorite = FractionalSortKey(rawValue: "a")
            $0.visitedAt = Date(timeIntervalSince1970: 1_000)
        }
        b.wall.set(40_000)
        try update(b, shared.page) {
            $0.cover = PageCover(source: .gallery("gradients_8"), offset: 0.2)
            $0.isSmallText = true
            $0.visitedAt = Date(timeIntervalSince1970: 2_000)
            $0.isTemplate = true
        }
        try exchange([a, b], numbering: numbering)
        for mac in [a, b] {
            let page = try #require(try mac.page(shared.page))
            #expect(page.cover == PageCover(source: .gallery("gradients_8"), offset: 0.2), "\(mac.name): позднее значение обложки")
            #expect(page.isFullWidth, "\(mac.name): широкую меняли только на A")
            #expect(page.isSmallText, "\(mac.name)")
            #expect(page.favorite?.rawValue == "a", "\(mac.name)")
            #expect(page.visitedAt == Date(timeIntervalSince1970: 2_000), "\(mac.name): позднее открытие")
            #expect(page.isTemplate, "\(mac.name)")
        }
    }

    @Test("Одновременная перестановка избранного на двух Mac сходится к одному порядку без потерь")
    func favoritesConverge() throws {
        var pages: [UUID] = []
        for title in ["Один", "Два", "Три", "Четыре"] {
            pages.append(try sharedPage(on: a, others: [b], numbering: numbering, title: title).page)
        }
        var key: FractionalSortKey?
        for page in pages {
            key = .between(key, nil)
            let favorite = key
            try update(a, page) { $0.favorite = favorite }
        }
        try exchange([a, b], numbering: numbering)
        let keys = try pages.map { try #require(try a.page($0)?.favorite) }
        // A ставит «Четыре» первой, B — «Один» последней, одновременно.
        a.wall.set(50_000)
        try update(a, pages[3]) { $0.favorite = .between(nil, keys[0]) }
        b.wall.set(50_000)
        try update(b, pages[0]) { $0.favorite = .between(keys[3], nil) }
        try exchange([a, b], numbering: numbering)

        func order(_ mac: SyncTestMac) throws -> [UUID] {
            try mac.store.favoritePages().map(\.id)
        }
        #expect(try order(a) == order(b))
        #expect(Set(try order(a)) == Set(pages), "ни одна строка не пропала")
        #expect(try order(a).first == pages[3] && order(a).last == pages[0])
    }

    @Test("Обложка-файл без самого файла ставит его в очередь докачки 002")
    func coverFileIsQueuedForDownload() throws {
        b.store.addWriteHook(AttachmentReferenceCounter())
        let shared = try sharedPage(on: a, others: [b], numbering: numbering)
        let ref = AttachmentRef(name: "Обложка.jpg", byteCount: 20_000_000, contentType: "public.jpeg", sha256: String(repeating: "d", count: 64))
        a.wall.set(30_000)
        try update(a, shared.page) { $0.cover = PageCover(source: .file(ref), offset: 0.4) }
        try exchange([a, b], numbering: numbering)
        #expect(try b.page(shared.page)?.cover?.attachment == ref)
        let state = try b.store.database.dbWriter.read { db in
            try String.fetchOne(db, sql: "SELECT state FROM attachment WHERE id = ?", arguments: [ref.id.uuidString.lowercased()])
        }
        #expect(state == "remote", "файл обложки ждёт скачивания")
    }

    @Test("Снимок v3 переносит новые поля страниц")
    func snapshotCarriesNewFields() throws {
        let page = try a.store.write { try $0.createPage(title: "Снимок").id }
        try update(a, page) {
            $0.cover = PageCover(source: .gallery("solid_beige"), offset: 0.7)
            $0.isFullWidth = true
            $0.isSmallText = true
            $0.favorite = FractionalSortKey(rawValue: "k")
            $0.visitedAt = Date(timeIntervalSince1970: 1_790_000_000)
            $0.isTemplate = true
        }
        let snapshot = try SyncSnapshot.make(seq: 7, from: a.store)
        #expect(snapshot.formatVersion >= 3)
        let fresh = try SyncTestMac(name: "Mac C", wallMillis: 50_000)
        _ = try fresh.store.write { tx in try ChangeMerger(localDeviceName: "Mac C").apply(snapshot, in: tx) }
        let copied = try #require(try fresh.page(page))
        let original = try #require(try a.page(page))
        #expect(copied.cover == original.cover && copied.isFullWidth && copied.isSmallText && copied.isTemplate)
        #expect(copied.favorite == original.favorite && copied.visitedAt == original.visitedAt)
        // Что видел снимок — и по новым полям: их метки позже всех остальных у этой страницы.
        let clocks = original.fieldClocks
        for stamp in [clocks.cover, clocks.isFullWidth, clocks.isSmallText, clocks.favorite, clocks.visitedAt, clocks.isTemplate] {
            #expect(snapshot.knowledge.covers(try #require(stamp)), "Снимок не знает метки \(String(describing: stamp))")
        }
    }
}
