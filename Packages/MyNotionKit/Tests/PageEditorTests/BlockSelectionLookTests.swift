import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Выделение через несколько блоков как в Notion (снимок Юрия 15.10.2026): как только выделение выходит за блок,
/// подсвечены блоки целиком — ровная подложка на всю ширину блока, на 6 левее текста абзаца и на 3 выше и ниже строк;
/// соседние блоки сливаются в одну подложку, номера и маркеры внутри; синий Notion rgba(35,131,226,0.14) в обеих темах.
@MainActor
@Suite("Выделение блоков целиком как в Notion")
struct BlockSelectionLookTests {
    static let wrapped = String(repeating: "Длинный абзац переносится на несколько строк. ", count: 5)
    static let specs: [EditorFixture.Spec] = [
        .numbered("Блок с текстом: нумерованный список"), .numbered("Список"), .bullet("Вложенный пункт", indent: 1),
        .paragraph(wrapped), .paragraph("Не выделен"),
    ]

    /// Выделение с середины пункта 0 до середины абзаца 3.
    private func makeEditor() throws -> EditorFixture {
        let editor = try EditorFixture(Self.specs)
        let start = editor.textLocation(ofBlock: 0) + 5
        let end = editor.textLocation(ofBlock: 3) + 10
        editor.textView.setSelectedRange(NSRange(location: start, length: end - start))
        return editor
    }

    /// Верх строки (высота 24, середина на середине шрифта) по базовой линии, в координатах окна текста.
    private func lineTop(baseline: CGFloat, in textView: PageTextView) -> CGFloat {
        let font = Typography.line(for: .paragraph).font
        return textView.textContainerOrigin.y + baseline - font.ascender - (24 - (font.ascender - font.descender)) / 2
    }

    /// Базовая линия последней строки блока.
    private func lastBaseline(ofBlock index: Int, in editor: EditorFixture) throws -> CGFloat {
        let textView = editor.textView
        let layoutManager = try #require(textView.textLayoutManager)
        let storage = try #require(textView.textContentStorage)
        let location = try #require(storage.location(storage.documentRange.location, offsetBy: editor.textLocation(ofBlock: index)))
        let fragment = try #require(layoutManager.textLayoutFragment(for: location))
        let line = try #require(fragment.textLineFragments.last { $0.characterRange.length > 0 })
        return fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
    }

    @Test("Подложка на блок: от края блока до края колонки, сливается с соседней, по 3 над и под строками")
    func blocksAreCoveredWhole() throws {
        let editor = try makeEditor()
        let textView = editor.textView
        #expect(textView.isBlockSelection, "Выделение через блоки показано полосами по тексту")
        let rects = textView.selectionHighlightRects()
        try #require(rects.count == 4, "Подложек \(rects.count): \(rects)")
        let origin = textView.textContainerOrigin
        let columnRight = origin.x + (textView.textContainer?.size.width ?? 0)
        for (index, rect) in rects.enumerated() {
            let line = try #require(textView.markerLine(ofBlockAt: index))
            // Край блока: у пунктов — край колонки маркера, у абзаца — начало текста; подложка на 6 левее.
            let blockLeft = origin.x + (Self.specs[index].kind == .paragraph ? line.caretX : line.markerColumn.minX)
            #expect(abs(rect.minX - (blockLeft - 6)) <= 0.5, "Блок \(index): подложка с \(rect.minX), край блока \(blockLeft)")
            #expect(abs(rect.maxX - (columnRight + 4)) <= 0.5, "Блок \(index): подложка до \(rect.maxX), колонка до \(columnRight)")
        }
        let firstTop = lineTop(baseline: try #require(textView.markerLine(ofBlockAt: 0)).baseline, in: textView)
        #expect(abs(rects[0].minY - (firstTop - 3)) <= 0.5, "Подложка с \(rects[0].minY), первая строка с \(firstTop)")
        for index in 0..<3 {
            #expect(abs(rects[index].maxY - rects[index + 1].minY) <= 0.01, "Подложки блоков \(index) и \(index + 1) не сходятся: \(rects)")
        }
        let lastBottom = lineTop(baseline: try lastBaseline(ofBlock: 3, in: editor), in: textView) + 24
        #expect(abs(rects[3].maxY - (lastBottom + 3)) <= 0.5, "Подложка до \(rects[3].maxY), последняя строка до \(lastBottom)")
        let lines = (lastBottom - lineTop(baseline: try #require(textView.markerLine(ofBlockAt: 3)).baseline, in: textView)) / 24
        #expect(lines >= 3, "Абзац 3 должен занимать несколько строк, а занимает \(lines)")
    }

    @Test("Цвет — синий Notion 0,14 в обеих темах, ровный и на стыке блоков; номер внутри; снаружи — страница; текст своего цвета")
    func blockHighlightColors() throws {
        let editor = try makeEditor()
        let rects = editor.textView.selectionHighlightRects()
        try #require(rects.count == 4)
        let line = try #require(editor.textView.markerLine(ofBlockAt: 1))
        let origin = editor.textView.textContainerOrigin
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let pixels = try ViewPixels(editor.textView, appearance: appearance)
            let page = pixels.blend(.clear, over: Palette.pageBackground, in: appearance)
            let notion = pixels.blend(NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 0.14),
                                      over: Palette.pageBackground, in: appearance)
            let name = appearance.rawValue
            let right = rects[1].maxX - 4
            for (place, point) in [("справа в блоке", NSPoint(x: right, y: rects[1].midY)),
                                   ("на стыке блоков", NSPoint(x: right, y: rects[1].maxY)),
                                   ("слева от номера", NSPoint(x: rects[1].minX + 2, y: rects[1].midY))] {
                let color = pixels.color(at: point, over: page)
                #expect(colorDistance(color, notion) <= 0.02, "\(name), \(place): \(color), ждём \(notion)")
            }
            let number = try #require(pixels.strongestInkColor(in: line.markerColumn.offsetBy(dx: origin.x, dy: origin.y), over: notion),
                                      "\(name): номера не видно в подложке")
            #expect(colorDistance(number, notion) > 0.2, "\(name): номер \(number) не нарисован поверх подложки")
            for (place, point) in [("над подложкой", NSPoint(x: right, y: rects[0].minY - 1.5)),
                                   ("справа от подложки", NSPoint(x: rects[1].maxX + 1.5, y: rects[1].midY)),
                                   ("под подложкой", NSPoint(x: right, y: rects[3].maxY + 1.5))] {
                let color = pixels.color(at: point, over: page)
                #expect(colorDistance(color, page) <= 0.02, "\(name), \(place): \(color) — не цвет страницы")
            }
            let text = try #require(pixels.strongestInkColor(in: rects[1], over: notion))
            let textColor = pixels.blend(Palette.textPrimary, over: Palette.pageBackground, in: appearance)
            #expect(colorDistance(text, textColor) <= 0.03, "\(name): текст в подложке \(text), ждём цвет текста")
        }
    }

    @Test("Выделение вернулось в один блок — снова полосы по тексту")
    func backToOneBlock() throws {
        let editor = try makeEditor()
        #expect(editor.textView.isBlockSelection)
        editor.select(inBlock: 1, "Список")
        #expect(!editor.textView.isBlockSelection)
        #expect(editor.textView.selectionHighlightRects().count == 1)
    }
}
