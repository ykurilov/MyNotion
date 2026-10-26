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

    @Test("Редактор показывает другую страницу — места у этой страницы нет, а не чужое")
    func otherPageEditorIsNotThisPage() throws {
        let fixture = try longPage()
        try scroll(fixture, to: 3_000)
        let place = PageScrollPlace()
        place.attach(fixture.textView)
        #expect(place.showsEditor(of: fixture.pageId))
        #expect(!place.showsEditor(of: UUID()))
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
        #expect(reopened.textView.selectedRange().location > 0, "выделение — у блока сверху, а не в начале страницы")
        reopened.textView.caret.showsWithoutKeyWindow = true
        reopened.window.makeFirstResponder(reopened.textView)
        reopened.textView.caret.update()
        #expect(!reopened.textView.caret.isShown, "после возврата курсора нет, пока не щёлкнули")
        reopened.textView.revealCaretAfterReturn()
        #expect(reopened.textView.caret.isShown, "после щелчка или клавиши курсор появляется")
    }

    @Test("Выше блока у верха вид узнал свою высоту уже после возврата места — блок остаётся на месте")
    func placeHoldsWhileLayoutAboveSettles() throws {
        let fixture = try longPage()
        let ids = fixture.document.blocks.map(\.id)
        // Колонки в середине страницы, видимая область — чуть ниже них: вид колонок в запасе над ней.
        fixture.step { _ = fixture.textView.placeBlocks([ids[101]], besideRightOf: ids[100]) }
        _ = try fixture.savedBlocks()
        try scroll(fixture, to: 3_000)
        let listIndex = try #require(fixture.document.blocks.firstIndex { $0.kind == .columnList })
        let listTop = try #require(fixture.textView.paragraphTop(ofBlockAt: listIndex))
        try scroll(fixture, to: listTop + 400)
        let place = PageScrollPlace()
        place.attach(fixture.textView)
        let saved = try #require(place.current())

        let reopened = try EditorFixture(reopening: fixture)
        reopened.window.displayIfNeeded()
        reopened.textView.restoreScrollPlace(saved)
        // Вид колонок выше видимой области стал выше на 300 точек — раскладка над блоком уточнилась.
        let list = try #require(reopened.document.blocks.first { $0.kind == .columnList }).id
        let width = reopened.textView.textContainer?.size.width ?? 0
        let estimated = reopened.textView.embeddedViews.height(of: list, width: width) ?? 0
        reopened.textView.embeddedViewHeightDidChange(list, height: estimated + 300, width: width)
        reopened.window.displayIfNeeded()

        place.attach(reopened.textView)
        let restored = try #require(place.current())
        #expect(restored.blockId == saved.blockId)
        #expect(abs(restored.offset - saved.offset) <= 1, "сдвиг был \(saved.offset), стал \(restored.offset)")
    }

    @Test("Под названием уже после возврата места появилась строка (обратные ссылки) — блок остаётся на месте")
    func placeHoldsWhenHeaderGrows() throws {
        let fixture = try longPage()
        try scroll(fixture, to: 300)
        let place = PageScrollPlace()
        place.attach(fixture.textView)
        let saved = try #require(place.current())

        let reopened = try EditorFixture(reopening: fixture)
        reopened.window.displayIfNeeded()
        reopened.textView.restoreScrollPlace(saved)
        // Счёт обратных ссылок читается в фоне и приходит после открытия: шапка выше на строку, текст ниже.
        reopened.textView.setUnderTitle(NSView(), height: 19)
        reopened.window.displayIfNeeded()

        place.attach(reopened.textView)
        let restored = try #require(place.current())
        #expect(restored.blockId == saved.blockId)
        #expect(abs(restored.offset - saved.offset) <= 1, "сдвиг был \(saved.offset), стал \(restored.offset)")
    }

    @Test("Блок в первых двух экранах — место возвращается точно, и следующая раскладка его не сдвигает")
    func placeNearTopIsExact() throws {
        // Богатая страница замера вкладок: иконка, заголовки, колонки, таблицы, виды блоков — оценка высот TextKit 2
        // выше блока у её начала ошибается сильнее, чем на ровных абзацах.
        let empty = try EditorFixture()
        let rich = try RichPageGenerator(parts: BlockKinds.richPageParts).ensure(in: empty.store)
        let fixture = try EditorFixture(opening: rich, from: empty)
        let place = PageScrollPlace()
        var misses: [String] = []
        for y in stride(from: CGFloat(40), through: 1_500, by: 70) {
            try scroll(fixture, to: y)
            place.attach(fixture.textView)
            guard let saved = place.current() else { continue }

            let reopened = try EditorFixture(opening: rich, from: fixture)
            reopened.window.displayIfNeeded()
            reopened.textView.restoreScrollPlace(saved)
            reopened.window.displayIfNeeded()
            reopened.textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
            reopened.window.displayIfNeeded()

            place.attach(reopened.textView)
            let restored = place.current()
            if restored?.blockId != saved.blockId || abs((restored?.offset ?? .infinity) - saved.offset) > 1 {
                misses.append("y \(Int(y)): сдвиг \(saved.offset) → \(restored.map { "\($0.offset)" } ?? "нет места")")
            }
        }
        #expect(misses.isEmpty, "\(misses)")
    }

    @Test("Колонки выше узнали высоту — блок на месте; человек прокрутил сам — якорь отпущен")
    func layoutShiftKeepsAnchorUntilOwnScroll() throws {
        let fixture = try longPage()
        let ids = fixture.document.blocks.map(\.id)
        fixture.step { _ = fixture.textView.placeBlocks([ids[101]], besideRightOf: ids[100]) }
        _ = try fixture.savedBlocks()
        try scroll(fixture, to: 3_000)
        let listIndex = try #require(fixture.document.blocks.firstIndex { $0.kind == .columnList })
        let listTop = try #require(fixture.textView.paragraphTop(ofBlockAt: listIndex))
        try scroll(fixture, to: listTop + 400)
        let place = PageScrollPlace()
        place.attach(fixture.textView)
        let saved = try #require(place.current())

        let reopened = try EditorFixture(reopening: fixture)
        reopened.window.displayIfNeeded()
        reopened.textView.restoreScrollPlace(saved)
        let list = try #require(reopened.document.blocks.first { $0.kind == .columnList }).id
        let width = reopened.textView.textContainer?.size.width ?? 0
        let estimated = reopened.textView.embeddedViews.height(of: list, width: width) ?? 0
        // Раскладка двигает прокрутку сама (TextKit 2 уточнил высоты выше) — это не прокрутка человека.
        reopened.textView.embeddedViewHeightDidChange(list, height: estimated + 200, width: width)
        reopened.window.displayIfNeeded()
        place.attach(reopened.textView)
        let held = try #require(place.current())
        #expect(held.blockId == saved.blockId)
        #expect(abs(held.offset - saved.offset) <= 1, "сдвиг был \(saved.offset), стал \(held.offset)")
        #expect(reopened.textView.scrollAnchor != nil, "якорь держится после сдвига раскладкой")

        // Человек прокрутил сам: следующая перекладка выше не возвращает страницу к блоку якоря.
        try scroll(reopened, to: visibleTop(reopened) + 500)
        reopened.textView.embeddedViewHeightDidChange(list, height: estimated + 400, width: width)
        reopened.window.displayIfNeeded()
        #expect(reopened.textView.scrollAnchor == nil, "якорь отпущен")
        place.attach(reopened.textView)
        #expect(place.current()?.blockId != saved.blockId, "страница не вернулась к блоку якоря")
    }

    @Test("Человек прокрутил сам — якорь отпущен: перекладка выше больше не двигает страницу")
    func ownScrollReleasesAnchor() throws {
        let fixture = try longPage()
        try scroll(fixture, to: 3_000)
        let place = PageScrollPlace()
        place.attach(fixture.textView)
        let saved = try #require(place.current())

        let reopened = try EditorFixture(reopening: fixture)
        reopened.window.displayIfNeeded()
        reopened.textView.restoreScrollPlace(saved)
        try scroll(reopened, to: 1_000)
        let top = visibleTop(reopened)
        reopened.textView.layoutSubtreeIfNeeded()
        reopened.window.displayIfNeeded()
        #expect(visibleTop(reopened) == top, "страница стоит там, куда её прокрутили")
    }

    @Test("Блока больше нет — страница остаётся сверху, без ошибки")
    func missingBlockKeepsTop() throws {
        let fixture = try longPage()
        fixture.window.displayIfNeeded()
        fixture.textView.restoreScrollPlace(TabScroll(blockId: UUID(), offset: 40))
        #expect(visibleTop(fixture) == 0)
    }
}
