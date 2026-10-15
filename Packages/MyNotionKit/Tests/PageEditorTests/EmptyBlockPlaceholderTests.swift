import AppKit
import Testing
@testable import PageEditor
import VisualStyle

/// Подсказки пустых блоков без курсора (ui-review 15.10.2026, № 22): у заголовков, пунктов и чекбоксов
/// видна всегда, у абзаца — только под курсором.
@MainActor
@Suite("Подсказки пустых блоков без курсора")
struct EmptyBlockPlaceholderTests {
    typealias Spec = EditorFixture.Spec

    /// Строка блока в координатах окна текста: от места курсора в пустом блоке до края колонки.
    private func textArea(ofBlock index: Int, in editor: EditorFixture) throws -> NSRect {
        let textView = editor.textView
        editor.placeCaret(inBlock: index)
        let caret = textView.convert(editor.window.convertFromScreen(
            textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)), from: nil)
        let line = try #require(textView.markerLine(ofBlockAt: index))
        return NSRect(x: caret.minX - 1, y: line.top + textView.textContainerOrigin.y, width: 400, height: line.height)
    }

    @Test("Пустые заголовок, пункт и чекбокс без курсора показывают подсказку там, где встал бы текст; пустой абзац — нет")
    func placeholdersWithoutCaret() throws {
        let specs: [Spec] = [.paragraph("Текст"), .heading(1, ""), .bullet(""), .checkbox(""), .paragraph(""), .paragraph("Ниже")]
        // Тот же текст, что в подсказках: по нему видно, где встал бы набранный текст.
        let filledSpecs: [Spec] = [.paragraph("Текст"), .heading(1, "Заголовок 1"), .bullet("Список"), .checkbox("Задача"), .paragraph(""), .paragraph("Ниже")]
        let editor = try EditorFixture(specs)
        let filled = try EditorFixture(filledSpecs)
        let textView = editor.textView
        var hintInk: [Int: NSRect] = [:]
        var areas: [Int: NSRect] = [:]
        for index in 1...4 {
            areas[index] = try textArea(ofBlock: index, in: editor)
            filled.placeCaret(inBlock: index)
            let hint = textView.emptyParagraphHint
            if let ink = try ViewPixels(hint, appearance: .aqua).inkBounds(in: hint.bounds) {
                hintInk[index] = ink.offsetBy(dx: hint.frame.minX, dy: hint.frame.minY)
            }
        }

        editor.placeCaret(inBlock: 0, at: 2)
        filled.placeCaret(inBlock: 0, at: 2)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let pixels = try ViewPixels(textView, appearance: appearance)
            let filledPixels = try ViewPixels(filled.textView, appearance: appearance)
            let page = Palette.pageBackground.resolved(in: appearance)
            for index in 1...3 {
                let area = try #require(areas[index])
                let ink = try #require(pixels.inkBounds(in: area, over: page), "Блок \(index), \(appearance.rawValue): подсказки нет")
                let text = try #require(filledPixels.inkBounds(in: area.insetBy(dx: -4, dy: 0), over: page))
                let underCaret = try #require(hintInk[index])
                #expect(abs(ink.minY - text.minY) <= 0.5 && abs(ink.maxY - text.maxY) <= 0.5,
                        "Блок \(index): подсказка \(ink), текст \(text) — не на одной строке")
                #expect(abs(ink.minX - underCaret.minX) <= 0.5, "Блок \(index): подсказка с \(ink.minX), под курсором с \(underCaret.minX)")
                let color = try #require(pixels.strongestInkColor(in: area, over: page))
                #expect(colorDistance(color, Palette.textSecondary.resolved(in: appearance)) < 0.1, "Блок \(index): цвет подсказки \(color)")
            }
            #expect(pixels.inkBounds(in: try #require(areas[4]), over: page) == nil, "Пустой абзац без курсора — без подсказки")
        }
    }

    @Test("Подсказка без курсора видна и когда текст не в фокусе")
    func placeholderWhenTextIsNotFocused() throws {
        let editor = try EditorFixture([.paragraph("Текст"), .heading(2, "")])
        let area = try textArea(ofBlock: 1, in: editor)
        editor.textView.header.focusTitle()
        #expect(editor.textView.emptyParagraphHint.isHidden)
        let page = Palette.pageBackground.resolved(in: .aqua)
        #expect(try ViewPixels(editor.textView, appearance: .aqua).inkBounds(in: area, over: page) != nil, "Пустой заголовок без фокуса — с подсказкой")
    }
}
