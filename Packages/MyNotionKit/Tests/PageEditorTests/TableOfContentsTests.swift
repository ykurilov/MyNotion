import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor

/// Оглавление (FR-106, contracts/blocks-and-keys.md, «Оглавление»): строки заголовков с отступами, обновление при правке,
/// переход к заголовку с раскрытием свёрнутых предков, подсказка без заголовков.
@MainActor
@Suite("Оглавление", .serialized)
struct TableOfContentsTests {
    typealias Spec = EditorFixture.Spec

    /// Вид оглавления, который поставила страница.
    func tocView(_ fixture: EditorFixture, block index: Int) throws -> TableOfContentsView {
        fixture.textView.blockViews.update()
        let host = try #require(fixture.textView.blockViews.view(for: fixture.document.blocks[index].id))
        return try #require(host.subviews.first as? TableOfContentsView)
    }

    @Test("Строки заголовков по порядку, отступ 24 на уровень")
    func entries() throws {
        let fixture = try EditorFixture([Spec(kind: .tableOfContents), .heading(1, "Введение"), .paragraph("текст"), .heading(2, "Часть"),
                                         .heading(3, "Глава"), .heading(1, "Итог")])
        #expect(TableOfContents.entries(in: fixture.document).map { "\($0.level) \($0.title)" } == ["0 Введение", "1 Часть", "2 Глава", "0 Итог"])
        let view = try tocView(fixture, block: 0)
        #expect(view.rowTitles == ["Введение", "Часть", "Глава", "Итог"])
        #expect(view.rowIndents == [0, 24, 48, 0])
        #expect(view.hint == nil)
    }

    @Test("Нет заголовков — серая подсказка")
    func emptyHint() throws {
        let fixture = try EditorFixture([Spec(kind: .tableOfContents), .paragraph("текст")])
        let view = try tocView(fixture, block: 0)
        #expect(view.rowTitles.isEmpty)
        #expect(view.hint == "Добавьте заголовки, чтобы появилось оглавление")
    }

    @Test("Правка заголовка обновляет оглавление и его высоту")
    func updatesOnEdit() throws {
        let fixture = try EditorFixture([Spec(kind: .tableOfContents), .heading(2, "Раз"), .paragraph("абзац")])
        let view = try tocView(fixture, block: 0)
        let factory = try #require(BlockViewFactories.shared.factory(for: .tableOfContents))
        let heightBefore = factory.height(for: fixture.document.blocks[0], width: 720) ?? 0
        fixture.placeCaret(inBlock: 1, at: nil)
        fixture.type("!")
        #expect(view.rowTitles == ["Раз!"])
        fixture.placeCaret(inBlock: 2, at: nil)
        fixture.perform(.setKind(.heading3))
        #expect(view.rowTitles == ["Раз!", "абзац"])
        #expect((factory.height(for: fixture.document.blocks[0], width: 720) ?? 0) > heightBefore)
        #expect((fixture.textView.blockAttachment(ofBlock: fixture.document.blocks[0].id)?.height(forWidth: 720) ?? 0) > heightBefore)
    }

    @Test("Щелчок по строке — курсор к заголовку, свёрнутые предки раскрыты")
    func goToHeading() throws {
        let fixture = try EditorFixture([Spec(kind: .tableOfContents), Spec(kind: .toggle, text: "Переключатель"),
                                         Spec(kind: .heading2, text: "Внутри", indent: 1), .paragraph("после")])
        let toggle = fixture.document.blocks[1].id
        fixture.textView.setCollapsed(true, ofBlock: toggle)
        #expect(fixture.textView.collapsedBlockIds.contains(toggle))
        let view = try tocView(fixture, block: 0)
        #expect(view.rowTitles == ["Внутри"])
        view.activateRow(0)
        #expect(!fixture.textView.collapsedBlockIds.contains(toggle))
        #expect(fixture.window.firstResponder === fixture.textView)
        #expect(fixture.textView.selectedRange().location == fixture.textLocation(ofBlock: 2))
    }
}
