import Foundation
import NotesCore
import Testing
@testable import PhonePageEditor

/// Правки с другого устройства, пока на iPhone правится страница: несохранённый набор не теряется.
@MainActor
struct ExternalChangesTests {
    @Test func otherBlockChangedElsewhereWhileTypingKeepsLocalText() throws {
        let page = try PhonePageFixture([.paragraph("пишу"), .paragraph("чужой")])
        page.session.setText(InlineText("пишу дальше", runs: [StyledRun(start: 5, length: 6, style: .italic)]), ofBlock: page.ids[0])

        try page.editElsewhere(page.ids[1]) { $0.text = InlineText("чужой с Mac", runs: [StyledRun(start: 8, length: 3, style: .bold)]) }

        #expect(page.texts == ["пишу дальше", "чужой с Mac"])
        #expect(page.document.blocks[0].text.runs == [StyledRun(start: 5, length: 6, style: .italic)])
        let saved = try page.savedBlocks()
        #expect(saved.map(\.text.string) == ["пишу дальше", "чужой с Mac"])
        #expect(saved[1].text.runs == [StyledRun(start: 8, length: 3, style: .bold)])
    }

    @Test func blockAddedElsewhereShowsUpInRows() throws {
        let page = try PhonePageFixture([.paragraph("один"), .paragraph("два")])
        try page.store.write { tx in
            let first = try #require(try tx.block(page.ids[0]))
            let second = try #require(try tx.block(page.ids[1]))
            _ = try tx.insertBlock(Block(pageId: page.pageId, kind: .checkbox, text: InlineText("с Mac"),
                                         sortKey: .between(first.sortKey, second.sortKey)))
        }
        _ = page.openDocuments.applyExternalChanges(toPages: [page.pageId])

        #expect(page.session.rows().map(\.block.text.string) == ["один", "с Mac", "два"])
        #expect(page.session.rows()[1].look == .text(.checkbox))
    }
}
