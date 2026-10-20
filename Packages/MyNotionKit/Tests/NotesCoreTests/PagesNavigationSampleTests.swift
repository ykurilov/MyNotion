import Foundation
import Testing
@testable import NotesCore

/// Дополнения 003 к эталону (quickstart.md): каждая история добавляет свою часть; этап 0 — ветка для дублирования.
@Suite("Дополнения 003 к эталону")
struct PagesNavigationSampleTests {
    @Test("Ветка для дублирования: 50 подстраниц, 5 000 блоков, 10 картинок; повтор ничего не добавляет")
    func duplicationBranch() throws {
        let folder = try TemporaryFolder()
        let store = try NotesStore(database: AppDatabase.open(at: folder.databaseURL), clock: HybridLogicalClock(deviceId: UUID()))
        var imageProps = BlockProps()
        imageProps.attachment = AttachmentRef(name: "картинка.png", byteCount: 10, contentType: "public.png", sha256: String(repeating: "e", count: 64))
        let sample = PagesNavigationSample(imageProps: imageProps)
        try sample.ensure(in: store)
        let outline = try store.pageOutline()
        let root = try #require(outline.first { $0.title == PagesNavigationSample.duplicationBranchTitle })
        var subpages = 0, blocks = 0, images = 0
        func visit(_ id: UUID) throws {
            let content = try #require(try store.pageContent(id))
            blocks += content.blocks.filter { $0.kind != .pageLink }.count
            images += content.blocks.filter { $0.kind == .image }.count
            for child in outline.filter({ $0.parentId == id }) {
                subpages += 1
                try visit(child.id)
            }
        }
        try visit(root.id)
        #expect(subpages == 50 && blocks == 5_000 && images == 10)
        try sample.ensure(in: store)
        #expect(try store.pageOutline().count == outline.count, "повтор ничего не добавляет")
    }
}
