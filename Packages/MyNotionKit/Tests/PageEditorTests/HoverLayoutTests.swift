import AppKit
import Testing
@testable import PageEditor
import NotesCore
import VisualStyle

@MainActor
@Suite("Наведение не меняет раскладку текста")
struct HoverLayoutTests {
    @Test("Медленное движение над заголовком и абзацами оставляет строки на месте")
    func hoverKeepsLineGeometry() throws {
        let editor = try EditorFixture([
            .heading(1, "Блок с текстом: заголовок 1"),
            .paragraph("Текст под заголовком для проверки наведения."),
            .bullet("Первый пункт"), .bullet("Второй пункт"), .paragraph(""),
        ], icon: "🥰")
        let view = editor.textView
        view.setCover(NSView(), height: 200)
        view.layoutSubtreeIfNeeded()
        let manager = try #require(view.textLayoutManager)
        manager.ensureLayout(for: manager.documentRange)
        view.layoutSubtreeIfNeeded()
        func frames() -> [CGRect] {
            var result: [CGRect] = []
            manager.enumerateTextLayoutFragments(from: manager.documentRange.location) { fragment in
                result.append(fragment.layoutFragmentFrame)
                return true
            }
            return result
        }
        editor.window.makeFirstResponder(view.header.titleField)
        let area = CGRect(x: view.textContainerOrigin.x + 2, y: view.textContainerOrigin.y,
                          width: view.textContainer!.size.width - 2, height: 180)
        func pixels() throws -> Data {
            let bitmap = try ViewPixels(view, appearance: .aqua, rect: area).bitmap
            return Data(bytes: try #require(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let initialPixels = try pixels()
        let initial = frames()
        #expect(initial.count >= editor.document.blocks.count)
        for index in 0..<4 {
            let line = try #require(view.markerLine(ofBlockAt: index))
            let point = NSPoint(x: view.textContainerOrigin.x + 50, y: view.textContainerOrigin.y + line.top + line.height / 2)
            for step in 0..<20 {
                let local = NSPoint(x: point.x + CGFloat(step) * 9, y: point.y)
                let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(local, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
                    context: nil, eventNumber: step, clickCount: 0, pressure: 0))
                view.mouseMoved(with: event)
                #expect(frames() == initial, "Блок \(index), движение \(step): строки сдвинулись")
                #expect(view.blockHandles.blockId == editor.document.blocks[index].id)
                #expect(try pixels() == initialPixels, "Блок \(index), движение \(step): рисунок текста изменился")
            }
        }
    }
}

@MainActor
@Suite("Подсветка строки блока-подстраницы при наведении")
struct PageLinkRowHighlightTests {
    @Test("Над подстраницей строка подсвечена, над абзацем и после ухода — нет")
    func highlightsOnlyPageLinkRow() throws {
        let editor = try EditorFixture([.paragraph("Текст"), EditorFixture.Spec(kind: .pageLink, link: UUID())])
        let view = editor.textView
        view.layoutSubtreeIfNeeded()
        let highlight = view.blockHandles.rowHighlight

        view.blockHandles.show(forBlockAt: 0, line: try #require(view.markerLine(ofBlockAt: 0)))
        #expect(highlight.isHidden)

        let line = try #require(view.markerLine(ofBlockAt: 1))
        view.blockHandles.show(forBlockAt: 1, line: line)
        #expect(!highlight.isHidden)
        let host = view.pageEditor
        // Прямоугольник по центру значка по вертикали, слева — небольшой отступ перед значком, справа — край колонки.
        let origin = view.textContainerOrigin
        let iconCenterY = origin.y + line.baseline - PageLinkPainter.titleFont.capHeight / 2
        let expectedCenter = host.convert(NSPoint(x: 0, y: iconCenterY), from: view).y
        #expect(abs(highlight.frame.midY - expectedCenter) < 0.5)
        #expect(highlight.frame.height == Metrics.PageLinkBlock.rowHighlightHeight)
        let iconLeft = host.convert(NSPoint(x: origin.x + line.markerColumn.midX - Metrics.PageLinkBlock.iconSize / 2, y: 0), from: view).x
        #expect(abs((iconLeft - highlight.frame.minX) - Metrics.PageLinkBlock.rowHighlightLeadingPadding) < 0.5)
        #expect(highlight.frame.maxX == host.convert(NSPoint(x: origin.x + view.textContainer!.size.width, y: 0), from: view).x)
        #expect(highlight.frame.minX >= view.blockHandles.frame.maxX)
        // Строка целиком внутри прямоугольника: поля сверху и снизу не меньше нуля и почти равны.
        let rowTop = host.convert(NSPoint(x: 0, y: origin.y + line.top), from: view).y
        #expect(highlight.frame.minY >= rowTop - 4)

        view.blockHandles.hide()
        #expect(highlight.isHidden)
    }
}

@MainActor
@Suite("Щелчок по строке блока-подстраницы")
struct PageLinkRowClickTests {
    @Test("Щелчок справа от названия открывает страницу и не ставит курсор")
    func clickBesideTitleOpensPage() throws {
        let target = UUID()
        let editor = try EditorFixture([.paragraph("Текст"), EditorFixture.Spec(kind: .pageLink, link: target)])
        let view = editor.textView
        view.layoutSubtreeIfNeeded()
        var opened: UUID?
        view.onOpenPage = { opened = $0 }
        let line = try #require(view.markerLine(ofBlockAt: 1))
        let origin = view.textContainerOrigin
        let farRight = NSPoint(x: origin.x + view.textContainer!.size.width - 20, y: origin.y + line.top + line.height / 2)
        #expect(view.linkedPage(at: farRight) == target)
        #expect(view.linkedPage(at: NSPoint(x: origin.x - 30, y: farRight.y)) == nil)
        let before = view.selectedRange()
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(farRight, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        #expect(opened == target)
        #expect(view.selectedRange() == before)
    }
}

@MainActor
@Suite("Щелчок ниже последнего блока")
struct TrailingParagraphClickTests {
    private func clickBelow(_ editor: EditorFixture) throws {
        let view = editor.textView
        view.layoutSubtreeIfNeeded()
        let last = try #require(view.markerLine(ofBlockAt: editor.document.blocks.count - 1))
        let point = NSPoint(x: view.textContainerOrigin.x + 100, y: view.textContainerOrigin.y + last.top + last.height + 40)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: editor.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        editor.step { view.mouseDown(with: click) }
    }

    @Test("После страницы-ссылки добавляется пустой абзац с курсором; ⌘Z убирает")
    func addsParagraphAfterPageLink() throws {
        let editor = try EditorFixture([.paragraph("Текст"), EditorFixture.Spec(kind: .pageLink, link: UUID())])
        try clickBelow(editor)
        #expect(editor.document.blocks.count == 3)
        #expect(editor.document.blocks[2].kind == .paragraph && editor.document.blocks[2].text.string.isEmpty)
        #expect(editor.textView.selectedRange().location == editor.textView.mapper.paragraphStart(ofBlockAt: 2))
        editor.undo()
        #expect(editor.document.blocks.count == 2)
    }

    @Test("Повторный щелчок не плодит пустые абзацы")
    func repeatedClickAddsNothing() throws {
        let editor = try EditorFixture([.paragraph("Текст"), EditorFixture.Spec(kind: .pageLink, link: UUID())])
        try clickBelow(editor)
        try clickBelow(editor)
        try clickBelow(editor)
        #expect(editor.document.blocks.count == 3)
    }

    @Test("Если последний абзац пуст, курсор встаёт в него без нового блока")
    func reusesEmptyLastParagraph() throws {
        let editor = try EditorFixture([.paragraph("Текст"), .paragraph("")])
        try clickBelow(editor)
        #expect(editor.document.blocks.count == 2)
        #expect(editor.textView.selectedRange().location == editor.textView.mapper.paragraphStart(ofBlockAt: 1))
    }

    @Test("После заголовка и списка с текстом тоже добавляется абзац")
    func addsParagraphAfterTextBlocks() throws {
        for last in [EditorFixture.Spec.heading(1, "Заголовок"), .bullet("Пункт")] {
            let editor = try EditorFixture([.paragraph("Текст"), last])
            try clickBelow(editor)
            #expect(editor.document.blocks.count == 3)
            #expect(editor.document.blocks[2].kind == .paragraph)
        }
    }
}

@MainActor
@Suite("Курсор в блоке-ссылке на страницу")
struct PageLinkCaretTests {
    @Test("Курсор не показывается в блоке-ссылке: ни при выделении, ни после возврата места")
    func caretNeverShownInPageLink() throws {
        let editor = try EditorFixture([EditorFixture.Spec(kind: .pageLink, link: UUID()), .paragraph("Текст")])
        let view = editor.textView
        view.caret.showsWithoutKeyWindow = true
        view.layoutSubtreeIfNeeded()
        editor.window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: view.mapper.paragraphStart(ofBlockAt: 0), length: 0))
        view.caret.update()
        #expect(!view.caret.isShown, "курсор в ссылке после выделения")

        view.restoreScrollPlace(TabScroll(blockId: editor.document.blocks[0].id, offset: 0))
        view.caret.update()
        #expect(!view.caret.isShown, "курсор в ссылке после возврата на страницу")

        view.setSelectedRange(NSRange(location: view.mapper.paragraphStart(ofBlockAt: 1), length: 0))
        view.caret.update()
        #expect(view.caret.isShown, "в обычном абзаце курсор должен быть")
    }
}
