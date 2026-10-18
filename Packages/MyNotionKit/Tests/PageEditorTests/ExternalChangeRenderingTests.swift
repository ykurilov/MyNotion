import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Правка с другого Mac перерисовывается в открытом редакторе (research R5): курсор остаётся в своём блоке
/// на том же месте, даже если блок выше стал длиннее или появился новый.
@MainActor
@Suite("Пришедшие правки в редакторе")
struct ExternalChangeRenderingTests {
    @Test("Блок выше курсора стал длиннее — курсор остаётся в своём блоке на том же месте")
    func caretStaysWhenBlockAboveChanges() throws {
        let fixture = try EditorFixture([.paragraph("первый"), .paragraph("второй"), .paragraph("третий")])
        fixture.placeCaret(inBlock: 1, at: 3)
        let ids = fixture.document.blocks.map(\.id)

        try fixture.applyRemote { tx in
            var first = try #require(try tx.block(ids[0]))
            first.text = InlineText("первый, сильно удлинённый на другом Mac")
            try tx.updateBlock(first)
        }

        #expect(fixture.texts == ["первый, сильно удлинённый на другом Mac", "второй", "третий"])
        #expect(fixture.textView.string.hasPrefix("первый, сильно удлинённый на другом Mac\nвторой\n"))
        let caret = fixture.textView.selectedRange()
        #expect(caret.length == 0)
        #expect(caret.location == fixture.textLocation(ofBlock: 1) + 3, "Курсор там же: в «второй» после «вто»")
    }

    @Test("Новый блок выше курсора и удаление блока ниже — курсор не сдвигается внутри своего блока")
    func caretStaysWhenBlocksAreInsertedAndRemoved() throws {
        let fixture = try EditorFixture([.paragraph("первый"), .paragraph("второй"), .paragraph("третий")])
        fixture.placeCaret(inBlock: 1, at: 2)
        let ids = fixture.document.blocks.map(\.id)

        try fixture.applyRemote { tx in
            let first = try #require(try tx.block(ids[0]))
            let second = try #require(try tx.block(ids[1]))
            try tx.insertBlock(Block(pageId: fixture.pageId, kind: .heading2, text: InlineText("новый заголовок"),
                                     sortKey: .between(first.sortKey, second.sortKey)))
            try tx.deleteBlock(ids[2])
        }

        #expect(fixture.texts == ["первый", "новый заголовок", "второй"])
        #expect(fixture.kinds == [.paragraph, .heading2, .paragraph])
        #expect(fixture.textView.selectedRange() == NSRange(location: fixture.textLocation(ofBlock: 2) + 2, length: 0))
    }

    @Test("После пришедшей правки набор продолжается в том же месте и сохраняется вместе с пришедшим")
    func typingContinuesAfterRemoteChange() throws {
        let fixture = try EditorFixture([.paragraph("первый"), .paragraph("второй")])
        fixture.placeCaret(inBlock: 1, at: nil)
        let ids = fixture.document.blocks.map(\.id)

        try fixture.applyRemote { tx in
            var first = try #require(try tx.block(ids[0]))
            first.text = InlineText("первый с другого Mac")
            try tx.updateBlock(first)
        }
        fixture.type("!")

        #expect(fixture.texts == ["первый с другого Mac", "второй!"])
        #expect(try fixture.savedBlocks().map(\.text.string) == ["первый с другого Mac", "второй!"])
    }
}

extension EditorFixture {
    /// Правка «с другого Mac»: прямо в базу, затем документ получает её как внешнюю.
    func applyRemote(_ change: (NotesTransaction) throws -> Void) throws {
        try store.write(change)
        let content = try #require(try store.pageContent(pageId))
        document.applyExternalChanges(content, conflicts: [])
    }
}
