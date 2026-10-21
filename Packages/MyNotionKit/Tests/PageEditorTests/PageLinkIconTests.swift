import AppKit
import Testing
@testable import PageEditor
import VisualStyle

/// Вид, который рисует переданное в перевёрнутых координатах, как фрагмент текста.
@MainActor
private final class DrawingView: NSView {
    let drawing: () -> Void
    init(size: NSSize, drawing: @escaping () -> Void) {
        self.drawing = drawing
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { drawing() }
}

@MainActor
@Suite("Значок подстраницы без иконки")
struct PageLinkIconTests {
    @Test("Подстраница без иконки — тот же лист со строчками, что в дереве слева (№ 18)")
    func pageLinkWithoutIconUsesDocumentGlyph() throws {
        let column = CGRect(x: 0, y: 0, width: 24, height: 30)
        let baseline: CGFloat = 20
        let size = Metrics.PageLinkBlock.iconSize
        let centerY = baseline - PageLinkPainter.titleFont.capHeight / 2
        let box = CGRect(x: column.midX - size / 2, y: centerY - size / 2, width: size, height: size)

        let link = DrawingView(size: NSSize(width: 200, height: 40)) {
            PageLinkPainter.draw(MentionDisplay(title: "Подстраница", icon: nil, state: .page), column: column, textStart: 30, baseline: baseline, maxX: 200)
        }
        let glyph = DrawingView(size: NSSize(width: 200, height: 40)) {
            DocumentGlyph.image(size: size, color: Palette.textSecondary).draw(in: box)
        }
        let iconArea = NSRect(x: 0, y: 0, width: 26, height: 40)
        let linkInk = try #require(ViewPixels(link, appearance: .aqua).inkBounds(in: iconArea))
        let glyphInk = try #require(ViewPixels(glyph, appearance: .aqua).inkBounds(in: iconArea))
        #expect(abs(linkInk.minX - glyphInk.minX) <= 0.5 && abs(linkInk.maxX - glyphInk.maxX) <= 0.5
                && abs(linkInk.minY - glyphInk.minY) <= 0.5 && abs(linkInk.maxY - glyphInk.maxY) <= 0.5,
                "Значок подстраницы \(linkInk), лист из дерева \(glyphInk)")
    }
}
