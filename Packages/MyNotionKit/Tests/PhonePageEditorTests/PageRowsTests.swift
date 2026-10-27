import Foundation
import NotesCore
import Testing
@testable import PhonePageEditor

/// Строки экрана: вложенность, номера списков, спрятанное под свёрнутым переключателем, вид блока.
@MainActor
struct PageRowsTests {
    @Test func numberedListsCountSiblingsAndRestartAfterOtherBlocks() throws {
        let page = try PhonePageFixture([
            .block(.numberedItem, "a"), .block(.numberedItem, "b"),
            .block(.numberedItem, "b.1", indent: 1), .block(.numberedItem, "b.2", indent: 1),
            .block(.numberedItem, "c"), .paragraph("перерыв"), .block(.numberedItem, "снова"),
        ])
        let rows = page.session.rows()
        #expect(rows.map(\.number) == [1, 2, 1, 2, 3, nil, 1])
        #expect(rows.map(\.indent) == [0, 0, 1, 1, 0, 0, 0])
    }

    @Test func collapsedToggleHidesItsChildrenOnly() throws {
        let page = try PhonePageFixture([
            .block(.toggle, "Раздел"), .paragraph("внутри", indent: 1), .block(.bulletItem, "глубже", indent: 2),
            .paragraph("после"),
        ])
        #expect(page.session.rows().count == 4)
        #expect(page.session.rows()[0].hasChildren)
        page.session.setCollapsed(true, toggle: page.ids[0])
        let rows = page.session.rows()
        #expect(rows.map(\.block.text.string) == ["Раздел", "после"])
        #expect(rows[0].isCollapsed)
    }

    @Test func blockLooks() throws {
        let page = try PhonePageFixture([
            .paragraph("абзац"), .block(.heading3, "h3"), .block(.quote, "цитата"), .block(.divider),
            .block(.pageLink, link: UUID()), .block(.image), .block(.callout, "выноска"), .block(.table),
        ])
        #expect(page.session.rows().map(\.look) == [
            .text(.paragraph), .text(.heading3), .text(.quote), .divider, .pageLink, .unsupported, .unsupported, .unsupported,
        ])
    }

    @Test func unsupportedBlockSummaryNamesKindAndText() {
        let pageId = UUID()
        let callout = Block(pageId: pageId, kind: .callout, text: InlineText("Важно"), sortKey: .between(nil, nil),
                            props: BlockProps(["icon": .string("💡")]))
        #expect(UnsupportedBlockSummary(callout) == UnsupportedBlockSummary(title: "Выноска", detail: "💡 Важно"))
        var bookmark = Block(pageId: pageId, kind: .bookmark, sortKey: .between(nil, nil))
        bookmark.props.url = URL(string: "https://kurilov.cloud")
        #expect(UnsupportedBlockSummary(bookmark) == UnsupportedBlockSummary(title: "Закладка", detail: "https://kurilov.cloud"))
        let image = Block(pageId: pageId, kind: .image, sortKey: .between(nil, nil))
        #expect(UnsupportedBlockSummary(image) == UnsupportedBlockSummary(title: "Картинка", detail: nil))
    }
}
