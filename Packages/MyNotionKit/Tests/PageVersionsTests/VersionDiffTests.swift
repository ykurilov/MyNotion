import Foundation
import Testing
@testable import NotesCore
@testable import PageVersions

/// Разница версий (data-model.md, «page_version.summary»): что менялось относительно прошлой версии и какие блоки
/// версии подсветить относительно текущей страницы.
@Suite("Версии: разница")
struct VersionDiffTests {
    let pageId = UUID()

    private func snapshot(title: String = "Страница", icon: String? = nil, cover: PageCover? = nil, fullWidth: Bool = false,
                          smallText: Bool = false, blocks: [Block]) -> PageSnapshot {
        let page = Page(id: pageId, title: title, icon: icon, sortKey: .between(nil, nil), createdAt: Date(), updatedAt: Date(),
                        cover: cover, isFullWidth: fullWidth, isSmallText: smallText)
        return PageSnapshot(page: page, blocks: blocks)
    }

    private func paragraphs(_ texts: [String]) -> [Block] {
        var key: FractionalSortKey?
        return texts.map { text in
            key = .between(key, nil)
            return Block(pageId: pageId, text: InlineText(text), sortKey: key!)
        }
    }

    @Test("Первая версия — «первая», без счёта изменений")
    func firstVersion() {
        let summary = VersionDiff.summary(from: nil, to: snapshot(blocks: paragraphs(["а"])))
        #expect(summary.isFirst)
        #expect(summary.lines == ["первая версия"])
    }

    @Test("Название, иконка, обложка и вид")
    func pageFields() {
        let before = snapshot(blocks: paragraphs(["а"]))
        let after = snapshot(title: "Новое", icon: "🌿", cover: PageCover(source: .gallery("solid_red")), fullWidth: true,
                             blocks: before.blocks(onPage: pageId))
        let summary = VersionDiff.summary(from: before, to: after)
        #expect(summary == VersionSummary(titleChanged: true, iconChanged: true, coverChanged: true, layoutChanged: true))
        #expect(summary.lines == ["изменено название", "изменена иконка", "изменена обложка", "изменён вид страницы"])
        #expect(VersionDiff.summary(from: before, to: snapshot(smallText: true, blocks: before.blocks(onPage: pageId))).layoutChanged)
    }

    @Test("Блоки добавлены, удалены, изменены; склонения подписей")
    func blocks() {
        var blocks = paragraphs(["а", "б", "в", "г", "д"])
        let before = snapshot(blocks: blocks)
        blocks[0].text = InlineText("а2")
        blocks[1].color = BlockColor(background: .yellow)
        blocks.remove(at: 4)
        blocks.append(contentsOf: (0..<3).map { Block(pageId: pageId, text: InlineText("новый \($0)"), sortKey: .between(blocks.last!.sortKey, nil)) })
        let summary = VersionDiff.summary(from: before, to: snapshot(blocks: blocks))
        #expect(summary == VersionSummary(blocksAdded: 3, blocksRemoved: 1, blocksChanged: 2))
        #expect(summary.lines == ["добавлено 3 блока", "удалён 1 блок", "изменено 2 блока"])
        #expect(VersionSummary(blocksAdded: 5, blocksRemoved: 21, blocksChanged: 11).lines
            == ["добавлено 5 блоков", "удалён 21 блок", "изменено 11 блоков"])
        #expect(VersionSummary(blocksAdded: 1).lines == ["добавлен 1 блок"])
    }

    @Test("Без изменений — пустая сводка и «без изменений»")
    func nothingChanged() {
        let before = snapshot(blocks: paragraphs(["а"]))
        let summary = VersionDiff.summary(from: before, to: before)
        #expect(summary == VersionSummary())
        #expect(summary.lines == ["без изменений"])
    }

    @Test("Подсветка: блоки версии, которых нет в текущей странице или которые в ней другие")
    func highlightedBlocks() {
        var current = paragraphs(["а", "б", "в"])
        let version = current
        current[1].text = InlineText("б2")
        current.remove(at: 2)
        current.append(Block(pageId: pageId, text: InlineText("новый"), sortKey: .between(current.last!.sortKey, nil)))
        let ids = VersionDiff.changedBlockIds(in: snapshot(blocks: version), comparedTo: snapshot(blocks: current))
        #expect(ids == [version[1].id, version[2].id])
    }

    @Test("Подсветка блока в колонке подсвечивает и его контейнер в потоке страницы")
    func highlightInsideContainer() {
        let list = Block(pageId: pageId, kind: .columnList, sortKey: .between(nil, nil))
        let column = Block(pageId: pageId, kind: .column, sortKey: .between(nil, nil), containerId: list.id)
        let inner = Block(pageId: pageId, text: InlineText("в колонке"), sortKey: .between(nil, nil), containerId: column.id)
        var changed = inner
        changed.text = InlineText("в колонке 2")
        let ids = VersionDiff.changedBlockIds(in: snapshot(blocks: [list, column, inner]), comparedTo: snapshot(blocks: [list, column, changed]))
        #expect(ids == [inner.id, list.id])
        #expect(VersionDiff.pageFlowRoot(of: inner.id, in: [list, column, inner]) == list.id)
    }
}
