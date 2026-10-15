import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Выделение через несколько блоков как в Notion (снимок Юрия 15.10.2026, тёмная тема): подсветка обтягивает текст
/// каждой строки на высоту строки, между блоками просвет, маркеры и номера не закрашены; синий Notion
/// rgba(35,131,226,0.28); текст в выделении своего цвета.
@MainActor
@Suite("Выделение текста как в Notion")
struct TextSelectionLookTests {
    static let texts = ["Блок с текстом: нумерованный список", "Список", "Абзац после пустого блока."]

    /// Выделены три блока целиком: два пункта и абзац; ниже пустой пункт.
    private func makeEditor() throws -> EditorFixture {
        let editor = try EditorFixture([.numbered(Self.texts[0]), .numbered(Self.texts[1]), .paragraph(Self.texts[2]), .numbered("")])
        let start = editor.textLocation(ofBlock: 0)
        let end = editor.textLocation(ofBlock: 2) + (Self.texts[2] as NSString).length
        editor.textView.setSelectedRange(NSRange(location: start, length: end - start))
        return editor
    }

    private func width(_ text: String) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: Typography.line(for: .paragraph).font]).size().width
    }

    @Test("По строке на блок: от начала до конца текста, высота строки, между блоками просвет")
    func highlightHugsText() throws {
        let editor = try makeEditor()
        let textView = editor.textView
        let rects = textView.selectionHighlightRects()
        try #require(rects.count == 3, "Полос \(rects.count): \(rects)")
        let font = Typography.line(for: .paragraph).font
        let origin = textView.textContainerOrigin
        for (index, rect) in rects.enumerated() {
            let line = try #require(textView.markerLine(ofBlockAt: index))
            let start = line.caretX + origin.x
            // Перевод строки внутри выделения — как пробел: полоса заходит за текст, как у Notion.
            let newline: CGFloat = index < 2 ? width(" ") : 0
            let end: CGFloat = start + width(Self.texts[index]) + newline
            let halfLeading: CGFloat = (24 - (font.ascender - font.descender)) / 2
            let top: CGFloat = origin.y + line.baseline - font.ascender - halfLeading
            #expect(abs(rect.minX - start) <= 0.5, "Блок \(index): полоса с \(rect.minX), текст с \(start) — номер не закрашен")
            #expect(abs(rect.maxX - end) <= 1, "Блок \(index): полоса до \(rect.maxX), ждём \(end)")
            #expect(abs(rect.minY - top) <= 0.5 && abs(rect.height - 24) <= 0.5, "Блок \(index): полоса \(rect), ждём верх \(top), высоту 24")
        }
        #expect(rects[0].maxY < rects[1].minY - 4 && rects[1].maxY < rects[2].minY - 4, "Между блоками просвет: \(rects)")
    }

    @Test("Цвет — синий Notion 0,28 в обеих темах; номер, просветы и место за текстом — цвета страницы; текст своего цвета")
    func highlightColors() throws {
        let editor = try makeEditor()
        let rects = editor.textView.selectionHighlightRects()
        try #require(rects.count == 3)
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
            let gap = pixels.color(at: NSPoint(x: rects[1].minX + 5, y: (rects[1].maxY + rects[2].minY) / 2), over: page)
            #expect(colorDistance(gap, page) <= 0.02, "\(name): между блоками \(gap) — не цвет страницы")
            let after = pixels.color(at: NSPoint(x: rects[2].maxX + 3, y: rects[2].midY), over: page)
            #expect(colorDistance(after, page) <= 0.02, "\(name): за текстом \(after) — не цвет страницы")
            let text = try #require(pixels.strongestInkColor(in: rects[2], over: notion))
            let textColor = pixels.blend(Palette.textPrimary, over: Palette.pageBackground, in: appearance)
            #expect(colorDistance(text, textColor) <= 0.03,
                    "\(name): текст в выделении \(text), ждём цвет текста, не белый")
        }
    }
}
