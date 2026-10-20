import Foundation
import Testing
@testable import NotesCore
@testable import PageVersions

/// Без потерь, круг восстановления (SC-208): на эталонной «богатой» странице «восстановить версию → ⌘Z» оставляет страницу
/// ровно такой, какой она была перед восстановлением, а ⇧⌘Z возвращает её ровно к версии. Остальные круги — в
/// `NotesCoreTests/NoLossRoundTripTests`; сами сценарии восстановления — в `VersionRestoreTests`.
@MainActor
@Suite("Без потерь: восстановление версии")
struct NoLossRestoreTests {
    /// Всё, что видит пользователь в странице и в блоках; служебные часы полей не в счёт.
    private struct Fingerprint: Equatable {
        var title: String, icon: String?, cover: PageCover?, isFullWidth: Bool, isSmallText: Bool
        var blocks: [[AnyHashable]]
    }

    /// Часть эталона: свёрнутый переключатель с ребёнком, колонки, выноска с цветом.
    private static let part = RichPagePart(name: "проба", blocks: [
        RichBlockSpec(.toggle, "Свёрнутый переключатель", isCollapsed: true),
        RichBlockSpec(.paragraph, "Ребёнок", indent: 1),
        RichBlockSpec(.columnList, contained: [
            RichBlockSpec(.column, contained: [RichBlockSpec(.paragraph, "В колонке")]),
            RichBlockSpec(.column, contained: [RichBlockSpec(.paragraph, "Во второй")]),
        ]),
        RichBlockSpec(.callout, "Выноска", color: BlockColor(background: .gray)),
    ])

    private func fingerprint(_ mac: VersionsTestMac, _ pageId: UUID) throws -> Fingerprint {
        let content = try #require(try mac.store.pageContent(pageId))
        let page = content.page
        return Fingerprint(title: page.title, icon: page.icon, cover: page.cover, isFullWidth: page.isFullWidth, isSmallText: page.isSmallText,
                           blocks: content.blocks.map { [$0.id, $0.kind, $0.text, $0.indent, $0.isChecked, $0.linkedPageId,
                                                         $0.sortKey, $0.containerId, $0.color, $0.props] as [AnyHashable?] }
                               .map { $0.map { $0 ?? AnyHashable("—") } })
    }

    @Test("Восстановить версию → ⌘Z: страница как до восстановления; ⇧⌘Z: как в версии")
    func restoreThenUndoOnRichPage() throws {
        let mac = try VersionsTestMac()
        mac.recorder.start()
        let pageId = try RichPageGenerator(parts: [Self.part]).ensure(in: mac.store)
        let subpage = try mac.tree.createSubpage(in: pageId, title: "Внутри эталона")
        try mac.updatePage(pageId) {
            $0.icon = "🧪"
            $0.cover = PageCover(source: .gallery("gradient_3"), offset: 0.3)
            $0.isFullWidth = true
            $0.isSmallText = true
        }
        mac.clock.advance(by: 61)
        let version = try #require(try mac.recorder.recordPending(pageId) ?? mac.versionList(pageId).first)
        let asInVersion = try fingerprint(mac, pageId)

        let blocks = try mac.blocks(pageId)
        try mac.updatePage(pageId) {
            $0.title = "Переименована"
            $0.cover = nil
            $0.isFullWidth = false
        }
        try mac.setText("правка первого блока", ofBlock: blocks[0].id)
        try mac.store.write { tx in
            for block in blocks[1...3] { try tx.deleteBlock(block.id) }
            try tx.insertBlock(Block(pageId: pageId, text: InlineText("лишний"), sortKey: .between(blocks.last?.sortKey, nil)))
        }
        let beforeRestore = try fingerprint(mac, pageId)
        #expect(beforeRestore != asInVersion)

        let restorer = VersionRestorer(recorder: mac.recorder, versions: mac.versions, operations: mac.tree)
        try mac.undoable { try restorer.restore(versionId: version.id, ofPage: pageId) }
        let restored = try fingerprint(mac, pageId)
        #expect(restored.title == asInVersion.title && restored.cover == asInVersion.cover)
        #expect(restored.blocks.map { $0[0] } == asInVersion.blocks.map { $0[0] }, "Блоки версии вернулись с прежними id")

        mac.undoManager.undo()
        #expect(try fingerprint(mac, pageId) == beforeRestore, "⌘Z: ровно как до восстановления")

        mac.undoManager.redo()
        #expect(try fingerprint(mac, pageId).blocks.map { $0[0] } == asInVersion.blocks.map { $0[0] })
        #expect(try mac.store.pageOutline().first { $0.id == subpage.id }?.parentId == pageId, "Подстраница на месте")
    }
}
