import AppKit
import Testing
@testable import PageEditor

/// Закрытая страница снимает свои виды по одному (`PageTextEditor.detachSubviews`). Прокрутка внутри страницы
/// (блок кода с длинными строками) своих частей не отдаёт: AppKit на снятие её `contentView` бросает исключение,
/// и приложение падало при уходе со страницы с таким блоком (галерея, фаза 10).
@MainActor
@Suite("Снятие видов закрытой страницы")
struct DetachSubviewsTests {
    @Test("Прокрутка внутри страницы снимается целиком, её вид прокрутки и полосы остаются при ней")
    func nestedScrollViewKeepsItsParts() {
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let block = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let scroll = NSScrollView(frame: block.bounds)
        scroll.hasHorizontalScroller = true
        let code = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 100))
        let line = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 20))
        code.addSubview(line)
        scroll.documentView = code
        block.addSubview(scroll)
        page.addSubview(block)
        let clip = scroll.contentView

        PageTextEditor.detachSubviews(of: page)

        #expect(page.subviews.isEmpty)
        #expect(block.subviews.isEmpty)
        #expect(clip.superview === scroll)
        #expect(scroll.documentView === code)
        #expect(code.subviews.isEmpty)
    }
}
