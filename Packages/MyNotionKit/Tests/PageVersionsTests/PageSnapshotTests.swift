import Foundation
import Testing
@testable import NotesCore
@testable import PageVersions

/// Снимок страницы для версии (data-model.md, «PageSnapshot»): поля страницы и все блоки всех потоков в формате записи 002,
/// JSON со сжатием LZFSE, `snapshotVersion` — текущая версия формата.
@MainActor
@Suite("Версии: снимок страницы")
struct PageSnapshotTests {
    let mac: VersionsTestMac

    init() throws {
        mac = try VersionsTestMac()
    }

    /// Страница с обложкой, видом, колонками, таблицей, цветом и свойствами блоков.
    private func richPage() throws -> UUID {
        try mac.store.write { tx in
            var page = try tx.createPage(title: "Снимок", icon: "📸")
            page.cover = PageCover(source: .gallery("gradients_3"), offset: 0.3)
            page.isFullWidth = true
            page.isSmallText = true
            try tx.updatePage(page)
            for block in try tx.blocks(ofPage: page.id) { try tx.deleteBlock(block.id) }
            var props = BlockProps.empty
            props.movedFrom = UUID()
            try tx.insertBlock(Block(pageId: page.id, kind: .heading1, text: InlineText("Заголовок"), sortKey: .between(nil, nil),
                                     color: BlockColor(text: .red), props: props))
            let list = try tx.insertBlock(Block(pageId: page.id, kind: .columnList, sortKey: .between(.between(nil, nil), nil)))
            let column = try tx.insertBlock(Block(pageId: page.id, kind: .column, sortKey: .between(nil, nil), containerId: list.id))
            try tx.insertBlock(Block(pageId: page.id, kind: .checkbox, text: InlineText("В колонке"), indent: 1, isChecked: true,
                                     sortKey: .between(nil, nil), containerId: column.id))
            return page.id
        }
    }

    @Test("Снимок содержит поля страницы и все блоки всех потоков с id, контейнером, ключом, цветом и свойствами")
    func capturesEverything() throws {
        let pageId = try richPage()
        let content = try #require(try mac.store.pageContent(pageId))
        let snapshot = PageSnapshot(page: content.page, blocks: content.blocks)
        #expect(snapshot.snapshotVersion == PageSnapshot.currentVersion)
        #expect(snapshot.title == "Снимок")
        #expect(snapshot.icon == "📸")
        #expect(snapshot.cover == PageCover(source: .gallery("gradients_3"), offset: 0.3))
        #expect(snapshot.isFullWidth && snapshot.isSmallText)
        #expect(snapshot.blocks.count == content.blocks.count)
        let restored = snapshot.blocks(onPage: pageId)
        for (original, copy) in zip(content.blocks, restored) {
            #expect(copy.id == original.id)
            #expect(copy.pageId == pageId)
            #expect(copy.kind == original.kind && copy.text == original.text && copy.indent == original.indent)
            #expect(copy.isChecked == original.isChecked && copy.linkedPageId == original.linkedPageId)
            #expect(copy.sortKey == original.sortKey && copy.containerId == original.containerId)
            #expect(copy.color == original.color && copy.props == original.props)
        }
    }

    @Test("Сжатие и разбор возвращают тот же снимок")
    func compressRoundTrip() throws {
        let pageId = try richPage()
        let content = try #require(try mac.store.pageContent(pageId))
        let snapshot = PageSnapshot(page: content.page, blocks: content.blocks)
        let data = try snapshot.compressed()
        #expect(try PageSnapshot(compressed: data) == snapshot)
        // Сжатый — не JSON как есть: LZFSE.
        #expect((try? JSONSerialization.jsonObject(with: data)) == nil)
    }

    @Test("Снимок более новой версии формата не читается — ошибка, а не пустая страница")
    func newerFormatRejected() throws {
        let content = try #require(try mac.store.pageContent(try mac.page("Новее", texts: ["а"]).id))
        var snapshot = PageSnapshot(page: content.page, blocks: content.blocks)
        snapshot.snapshotVersion = PageSnapshot.currentVersion + 1
        let data = try snapshot.compressed()
        #expect(throws: PageSnapshotError.newerFormat(PageSnapshot.currentVersion + 1)) { try PageSnapshot(compressed: data) }
    }

    @Test("Снимок 1 000 блоков: размер записан")
    func thousandBlocksSize() throws {
        let texts = (0..<1_000).map { "Блок \($0 + 1): строка текста средней длины, как на «богатой» странице 002, с цифрами \($0 * 37)." }
        let page = try mac.page("Тысяча", texts: texts)
        let content = try #require(try mac.store.pageContent(page.id))
        let data = try PageSnapshot(page: content.page, blocks: content.blocks).compressed()
        print("Снимок 1 000 блоков: \(data.count / 1024) КБ сжатый")
        #expect(data.count < 200 * 1024, "Снимок 1 000 абзацев больше 200 КБ")
    }
}
