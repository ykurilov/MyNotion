import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Подсказка «Введите «/»…» после удаления выделения, которое начиналось в заголовке (страница «Продающие ИИ-видео»,
/// 01.11.2026): подсказка выходила крупным шрифтом заголовка и наезжала на ссылку на страницу над пустым абзацем.
@MainActor
@Suite("Подсказка пустого абзаца после удаления выделения")
struct EmptyParagraphHintAfterDeletionTests {
    typealias Spec = EditorFixture.Spec

    @Test("Выделение от заголовка до пустого абзаца удалено — подсказка обычным шрифтом в строке абзаца, ссылка видна")
    func hintAfterDeletingFromHeading() throws {
        let editor = try EditorFixture([.paragraph("Выше"), Spec(kind: .pageLink, link: UUID()), .heading(1, "Продающие ИИ-видео"),
                                        .paragraph("Текст"), .paragraph("")])
        let textView = editor.textView
        let start = editor.textLocation(ofBlock: 2)
        editor.step { textView.setSelectedRange(NSRange(location: start, length: editor.textLocation(ofBlock: 4) - start)) }
        editor.press(#selector(NSResponder.deleteBackward(_:)))

        #expect(editor.kinds == [.paragraph, .pageLink, .paragraph])
        #expect(textView.selectedRange() == NSRange(location: editor.textLocation(ofBlock: 2), length: 0))
        let hint = textView.emptyParagraphHint
        #expect(!hint.isHidden)
        let paragraphFont = Typography.line(for: .paragraph).font
        #expect(hint.font?.pointSize == paragraphFont.pointSize, "Шрифт подсказки \(String(describing: hint.font))")
        let typingFont = textView.typingAttributes[.font] as? NSFont
        #expect(typingFont?.pointSize == paragraphFont.pointSize, "Шрифт набора \(String(describing: typingFont))")

        let origin = textView.textContainerOrigin
        let paragraphLine = try #require(textView.markerLine(ofBlockAt: 2))
        let linkLine = try #require(textView.markerLine(ofBlockAt: 1))
        #expect(hint.frame.minY >= linkLine.top + linkLine.height + origin.y - 0.5,
                "Подсказка \(hint.frame) наезжает на ссылку (строка \(linkLine.top)…\(linkLine.top + linkLine.height))")
        #expect((paragraphLine.top + origin.y...paragraphLine.top + paragraphLine.height + origin.y).contains(hint.frame.midY),
                "Подсказка \(hint.frame) не в строке абзаца")
        let linkArea = NSRect(x: 0, y: linkLine.top + origin.y, width: textView.bounds.width, height: linkLine.height)
        let page = Palette.pageBackground.resolved(in: .aqua)
        #expect(try ViewPixels(textView, appearance: .aqua).inkBounds(in: linkArea, over: page) != nil, "Ссылки не видно")
    }
}
