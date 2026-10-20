import AppKit
import Foundation
import Testing
import NotesCore
@testable import PageEditor

/// Место прокрутки для вкладок и «назад/вперёд» (T049, research R5): блок у верха видимой области и сдвиг;
/// новый редактор той же страницы возвращает видимую область туда же (`relocateViewport` TextKit 2).
@MainActor
@Suite("Место прокрутки страницы")
struct PageScrollPlaceTests {
    private func longPage() throws -> EditorFixture {
        try EditorFixture((0..<400).map { .paragraph("Абзац номер \($0): немного текста, чтобы строка была похожа на настоящую.") })
    }

    private func scroll(_ fixture: EditorFixture, to y: CGFloat) throws {
        let scrollView = try #require(fixture.textView.enclosingScrollView)
        fixture.textView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        fixture.window.displayIfNeeded()
    }

    private func visibleTop(_ fixture: EditorFixture) -> CGFloat {
        fixture.textView.enclosingScrollView?.contentView.bounds.minY ?? 0
    }

    @Test("Страница в самом верху — места нет: новая вкладка откроется сверху")
    func topOfPageHasNoPlace() throws {
        let fixture = try longPage()
        let place = PageScrollPlace()
        place.attach(fixture.textView)
        #expect(place.current() == nil)
    }

    @Test("Ушли со страницы, прокрученной вниз, — новый редактор той же страницы встаёт на то же место")
    func placeSurvivesNewEditor() throws {
        let fixture = try longPage()
        try scroll(fixture, to: 3_000)
        let before = visibleTop(fixture)
        #expect(before > 2_000, "страница прокрутилась")
        let place = PageScrollPlace()
        place.attach(fixture.textView)
        let saved = try #require(place.current())
        let index = try #require(fixture.document.index(ofBlock: saved.blockId))
        #expect(index > 20, "у верха — блок из середины страницы, а не первый")

        let reopened = try EditorFixture(reopening: fixture)
        reopened.window.displayIfNeeded()
        reopened.textView.restoreScrollPlace(saved)
        // Высоты выше блока у нового редактора — оценка TextKit, поэтому сверяется место, а не координата.
        place.attach(reopened.textView)
        let restored = try #require(place.current())
        #expect(restored.blockId == saved.blockId)
        #expect(abs(restored.offset - saved.offset) <= 1, "сдвиг был \(saved.offset), стал \(restored.offset)")
        #expect(reopened.textView.selectedRange().location > 0, "курсор — у блока сверху, а не в начале страницы")
    }

    @Test("Блока больше нет — страница остаётся сверху, без ошибки")
    func missingBlockKeepsTop() throws {
        let fixture = try longPage()
        fixture.window.displayIfNeeded()
        fixture.textView.restoreScrollPlace(TabScroll(blockId: UUID(), offset: 40))
        #expect(visibleTop(fixture) == 0)
    }
}
