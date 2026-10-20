import Foundation
import Testing
@testable import NotesCore
@testable import PageSearch

@Suite("Поиск по упоминаниям и датам (data-model.md, «Поиск»)")
struct MentionSearchTests {
    @Test("Упоминание индексируется названием страницы на момент записи, дата — словами")
    func mentionIndexedByTitle() throws {
        let library = try SearchLibrary()
        let target = try library.page("Квартальный отчёт")
        let page = try library.page("Встречи")
        try library.store.write { tx in
            var block = try #require(try tx.blocks(ofPage: page.id).first)
            let date = DateMention(start: "2026-10-20", includesTime: false, timeZone: "Europe/Moscow")
            block.text = InlineText("Обсудить \u{FFFC} \u{FFFC}", runs: [StyledRun(start: 9, length: 1, style: .mention(target.id)),
                                                                     StyledRun(start: 11, length: 1, style: .date(date))])
            try tx.updateBlock(block)
        }
        #expect(try library.foundPageIds("обсудить кварт") == [page.id])
        #expect(try library.foundPageIds("октября").contains(page.id))
    }
}
