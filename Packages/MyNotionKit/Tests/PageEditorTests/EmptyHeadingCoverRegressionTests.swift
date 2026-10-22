import AppKit
import Testing
@testable import PageEditor
import VisualStyle

/// Регрессия по снимку Юрия 22.10: серая подсказка пустого heading2 не пересекает page-title.
/// Подготовлено после source-анализа; до снятия Xcode license blocker НЕ запускалось.
/// Невидимое окно проверяет координаты и рисунок; живые transition/return проверяются отдельно на iMac.
@MainActor
@Suite("Пустой заголовок под обложкой: title, подсказка и блок")
struct EmptyHeadingCoverRegressionTests {
    private enum Focus: CaseIterable { case title, emptyBody, away }

    @Test("Открытие с cover и добавление cover после отрисовки: оба источника подсказки ниже title",
          arguments: [false, true])
    func emptyHeadingStaysOnItsOwnLine(initiallyCovered: Bool) throws {
        let editor = try makeEditor()
        if !initiallyCovered {
            try inspectFocusCycle(editor, stage: "до добавления обложки")
        }
        editor.textView.setCover(PlaceholderCoverProbe(), height: 280)
        try inspectFocusCycle(editor, stage: initiallyCovered ? "первое открытие с обложкой" : "добавление к открытой странице")

        let scroll = try #require(editor.textView.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        // Не переносим фокус в body во время прокрутки: это само возвращает первый блок в viewport.
        editor.textView.header.focusTitle()
        try inspect(editor, focus: .title, stage: "прокрутка")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try inspectFocusCycle(editor, stage: "возврат прокрутки")

        for width in [CGFloat(1740), 1000, 1740] {
            editor.window.setContentSize(NSSize(width: width, height: 1000))
            scroll.frame = editor.window.contentLayoutRect
            editor.textView.frame.size.width = scroll.contentSize.width
            try inspectFocusCycle(editor, stage: "ширина \(width)")
        }

        // Перечитывание того же документа проверяет fresh editor. Это НЕ live-переход дерева/вкладок.
        _ = try editor.savedBlocks()
        let reopened = try EditorFixture(reopening: editor)
        reopened.textView.setCover(PlaceholderCoverProbe(), height: 280)
        try inspectFocusCycle(reopened, stage: "документ открыт заново")
    }

    private func makeEditor() throws -> EditorFixture {
        let editor = try EditorFixture([.heading(2, "")] + (0..<40).map { .paragraph("Контрольный абзац \($0)") })
        editor.document.setTitle("Название страницы", origin: nil)
        return editor
    }

    private func inspectFocusCycle(_ editor: EditorFixture, stage: String) throws {
        for focus in Focus.allCases {
            switch focus {
            case .title: editor.textView.header.focusTitle()
            case .emptyBody:
                editor.window.makeFirstResponder(editor.textView)
                editor.placeCaret(inBlock: 0)
            case .away: editor.window.makeFirstResponder(nil)
            }
            try inspect(editor, focus: focus, stage: stage)
        }
    }

    private func inspect(_ editor: EditorFixture, focus: Focus, stage: String) throws {
        let view = editor.textView
        // Снимаем рисунок ДО markerLine/ensureLayout: диагностическое чтение не должно исправлять кадр.
        let pixels = try ViewPixels(view, appearance: .aqua)
        let line = try #require(view.markerLine(ofBlockAt: 0))
        let title = view.header.convert(view.header.titleField.frame, to: view)
        let origin = view.textContainerOrigin
        let block = NSRect(x: origin.x + line.caretX, y: origin.y + line.top, width: 400, height: line.height)
        #expect(title.maxY + 19 <= block.minY, "\(stage), \(focus): title \(title) пересекает блок \(block)")

        if focus == .emptyBody {
            let hint = view.emptyParagraphHint
            #expect(!hint.isHidden, "\(stage): focused hint не видна")
            #expect(hint.stringValue == "Заголовок 2")
            #expect(!hint.frame.intersects(title), "\(stage): hint \(hint.frame) поверх title \(title)")
            #expect(abs(hint.frame.minY + hint.firstBaselineOffsetFromTop - origin.y - line.baseline) <= 0.5,
                    "\(stage): hint и реальный block baseline разошлись")
            let hintPixels = try ViewPixels(hint, appearance: .aqua)
            let ink = try #require(hintPixels.inkBounds(in: hint.bounds))
            let placed = ink.offsetBy(dx: hint.frame.minX, dy: hint.frame.minY)
            #expect(placed.minY >= block.minY - 1 && placed.maxY <= block.maxY + 1,
                    "\(stage): focused hint ink \(placed) вне строки \(block)")
        } else {
            #expect(view.emptyParagraphHint.isHidden, "\(stage): focused hint осталась после потери фокуса")
            let ink = try #require(pixels.inkBounds(in: block, over: Palette.pageBackground.resolved(in: .aqua)),
                                   "\(stage), \(focus): persistent placeholder не нарисован на строке блока")
            #expect(!ink.intersects(title), "\(stage): persistent hint \(ink) поверх title \(title)")
            let color = try #require(pixels.strongestInkColor(in: block, over: Palette.pageBackground.resolved(in: .aqua)))
            #expect(colorDistance(color, Palette.textSecondary.resolved(in: .aqua)) < 0.1,
                    "\(stage): измерена не серая placeholder-строка")
        }
    }
}

@MainActor
private final class PlaceholderCoverProbe: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemPurple.setFill()
        bounds.fill()
    }
}
