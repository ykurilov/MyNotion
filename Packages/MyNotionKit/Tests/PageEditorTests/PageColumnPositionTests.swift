import AppKit
import Testing
@testable import PageEditor
import VisualStyle

/// Колонка страницы стоит на одном месте при любой длине страницы (раунд 2, № 23).
@MainActor
struct PageColumnPositionTests {
    /// Левый край колонки в координатах прокрутки, когда полоса прокрутки занимает место (мышь без трекпада).
    private func columnLeft(blocks: Int) throws -> (left: CGFloat, clipWidth: CGFloat, scrollWidth: CGFloat) {
        let editor = try EditorFixture(Array(repeating: .paragraph("Строка страницы"), count: blocks))
        let scroll = PageTextEditor.makeScrollView(around: editor.textView, frame: editor.window.contentLayoutRect)
        scroll.scrollerStyle = .legacy
        editor.window.contentView = scroll
        editor.textView.textLayoutManager?.ensureLayout(for: editor.textView.textLayoutManager!.documentRange)
        editor.textView.sizeToFit()
        scroll.tile()
        editor.window.layoutIfNeeded()
        let origin = editor.textView.convert(editor.textView.textContainerOrigin, to: scroll)
        return (origin.x, scroll.contentView.bounds.width, scroll.frame.width)
    }

    @Test("Длинная страница с полосой прокрутки: колонка там же, где у короткой (раунд 2, № 23)")
    func columnStaysPut() throws {
        let short = try columnLeft(blocks: 1)
        let long = try columnLeft(blocks: 80)
        #expect(long.clipWidth < long.scrollWidth, "полоса прокрутки длинной страницы не заняла места: проверка ничего не проверяет")
        #expect(abs(long.left - short.left) <= 0.5, "колонка длинной страницы \(long.left), короткой \(short.left)")
        #expect(abs(short.left - (short.scrollWidth - Metrics.Page.columnWidth) / 2) <= 0.5, "колонка не по центру: \(short.left)")
    }
}
