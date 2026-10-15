import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Выделение текста как в Notion (снимок Юрия 15.10.2026, тёмная тема): подсветка обтягивает текст каждой строки
/// на высоту строки — и внутри блока, и через несколько блоков; между блоками просвет, номер не закрашен;
/// синий Notion rgba(35,131,226,0.28); текст в выделении своего цвета. Режим выделения блоков — `BlockSelectionLookTests`.
@MainActor
@Suite("Выделение текста как в Notion")
struct TextSelectionLookTests {
    static let texts = ["Блок с текстом: нумерованный список", "Список", "Абзац после пустого блока."]

    /// Выделен текст пункта 0 целиком, без перевода строки.
    private func makeEditor() throws -> EditorFixture {
        let editor = try EditorFixture([.numbered(Self.texts[0]), .numbered(Self.texts[1]), .paragraph(Self.texts[2]), .numbered("")])
        editor.select(inBlock: 0, Self.texts[0])
        return editor
    }

    /// Текст пункта правее края колонки.
    static let textStartOffset: CGFloat = 30

    private func width(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: Typography.line(for: .paragraph).font]).size().width
    }

    @Test("Полоса от начала до конца текста на высоту строки, номер не закрашен")
    func highlightHugsText() throws {
        let editor = try makeEditor()
        let textView = editor.textView
        let rects = textView.selectionHighlightRects()
        try #require(rects.count == 1, "Полос \(rects.count): \(rects)")
        let rect = rects[0]
        let font = Typography.line(for: .paragraph).font
        let origin = textView.textContainerOrigin
        let line = try #require(textView.markerLine(ofBlockAt: 0))
        let start = line.caretX + origin.x
        let end = start + width(Self.texts[0])
        let halfLeading: CGFloat = (24 - (font.ascender - font.descender)) / 2
        let top: CGFloat = origin.y + line.baseline - font.ascender - halfLeading
        #expect(!textView.isBlockSelection, "Выделение внутри блока показано блоком целиком")
        #expect(abs(rect.minX - start) <= 0.5, "Полоса с \(rect.minX), текст с \(start) — номер не закрашен")
        #expect(abs(rect.maxX - end) <= 1, "Полоса до \(rect.maxX), ждём \(end)")
        #expect(abs(rect.minY - top) <= 0.5 && abs(rect.height - 24) <= 0.5, "Полоса \(rect), ждём верх \(top), высоту 24")
    }

    @Test("Через несколько блоков — тоже полосы по тексту: по строке на блок, между блоками просвет, номера не закрашены")
    func acrossBlocksStaysText() throws {
        let editor = try EditorFixture([.numbered(Self.texts[0]), .numbered(Self.texts[1]), .paragraph(Self.texts[2]), .numbered("")])
        let start = editor.textLocation(ofBlock: 0) + 6
        let end = editor.textLocation(ofBlock: 2) + 5
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: start, length: end - start))
        #expect(!textView.isBlockSelection, "Выделение текста через блоки показано блоками")
        let rects = textView.selectionHighlightRects()
        try #require(rects.count == 3, "Полос \(rects.count): \(rects)")
        let origin = textView.textContainerOrigin
        for (index, rect) in rects.enumerated() {
            let line = try #require(textView.markerLine(ofBlockAt: index))
            let textStart = line.caretX + origin.x
            #expect(rect.minX >= textStart - 0.5, "Блок \(index): полоса с \(rect.minX), текст с \(textStart) — номер закрашен")
            #expect(abs(rect.height - 24) <= 0.5, "Блок \(index): высота полосы \(rect.height)")
        }
        #expect(rects[0].minX > origin.x + Self.textStartOffset + 20, "Первая полоса не с середины текста: \(rects[0])")
        #expect(rects[2].maxX < origin.x + width(Self.texts[2]), "Последняя полоса дальше выделенного: \(rects[2])")
        #expect(rects[0].maxY < rects[1].minY - 4 && rects[1].maxY < rects[2].minY - 4, "Между блоками просвет: \(rects)")
    }

    @Test("Выделение до начала следующего блока — всё ещё один блок: полосы, перевод строки шириной в пробел")
    func newlineStaysInsideBlock() throws {
        let editor = try EditorFixture([.numbered(Self.texts[0]), .numbered(Self.texts[1])])
        let start = editor.textLocation(ofBlock: 0)
        editor.textView.setSelectedRange(NSRange(location: start, length: editor.textLocation(ofBlock: 1) - start))
        let rects = editor.textView.selectionHighlightRects()
        try #require(rects.count == 1, "Полос \(rects.count): \(rects)")
        #expect(!editor.textView.isBlockSelection)
        let line = try #require(editor.textView.markerLine(ofBlockAt: 0))
        let end = line.caretX + editor.textView.textContainerOrigin.x + width(Self.texts[0]) + width(" ")
        #expect(abs(rects[0].maxX - end) <= 1, "Полоса до \(rects[0].maxX), ждём \(end)")
    }

    @Test("Цвет — синий Notion 0,28 в обеих темах; номер и место за текстом — цвета страницы; текст своего цвета")
    func highlightColors() throws {
        let editor = try makeEditor()
        let rects = editor.textView.selectionHighlightRects()
        try #require(rects.count == 1)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let pixels = try ViewPixels(editor.textView, appearance: appearance)
            // Эталоны смешаны так же, как снимок: в его цветовом пространстве.
            let page = pixels.blend(.clear, over: Palette.pageBackground, in: appearance)
            let notion = pixels.blend(NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 0.28),
                                      over: Palette.pageBackground, in: appearance)
            let name = appearance.rawValue
            let tail = pixels.color(at: NSPoint(x: rects[0].maxX - 1.5, y: rects[0].midY), over: page)
            #expect(colorDistance(tail, notion) <= 0.02, "\(name): подсветка \(tail), ждём \(notion)")
            let number = pixels.color(at: NSPoint(x: rects[0].minX - 3, y: rects[0].midY), over: page)
            #expect(colorDistance(number, page) <= 0.02, "\(name): у номера \(number) — не цвет страницы")
            let after = pixels.color(at: NSPoint(x: rects[0].maxX + 3, y: rects[0].midY), over: page)
            #expect(colorDistance(after, page) <= 0.02, "\(name): за текстом \(after) — не цвет страницы")
            let text = try #require(pixels.strongestInkColor(in: rects[0], over: notion))
            let textColor = pixels.blend(Palette.textPrimary, over: Palette.pageBackground, in: appearance)
            #expect(colorDistance(text, textColor) <= 0.03, "\(name): текст в выделении \(text), ждём цвет текста, не белый")
        }
    }
}
