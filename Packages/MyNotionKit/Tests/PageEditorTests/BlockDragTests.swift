import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Перетаскивание блока за «⋮⋮» как в Notion: за мышью едет полупрозрачная копия блока вместе с вложенными,
/// место сброса — синяя линия, исходный блок стоит на месте до отпускания, Esc отменяет.
@MainActor
@Suite("Перетаскивание блока за «⋮⋮»")
struct BlockDragTests {
    /// Нумерованный пункт с вложенным чекбоксом между двумя абзацами; курсор в первом абзаце.
    private func makeEditor() throws -> EditorFixture {
        let editor = try EditorFixture([.paragraph("Первый"), .numbered("Пункт"), .checkbox("Вложенный", indent: 1), .paragraph("Последний")])
        editor.placeCaret(inBlock: 0)
        return editor
    }

    /// Середина «⋮⋮» у блока `index` (координаты окна текста).
    private func grip(ofBlock index: Int, in editor: EditorFixture) throws -> NSPoint {
        let textView = editor.textView
        textView.blockHandles.show(forBlockAt: index, line: try #require(textView.markerLine(ofBlockAt: index)))
        let handle = textView.blockHandles.dragHandle
        return handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: textView)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in editor: EditorFixture) throws {
        let textView = editor.textView
        let event = try #require(NSEvent.mouseEvent(with: type, location: textView.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                                    windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        let handle = textView.blockHandles.dragHandle
        switch type {
        case .leftMouseDown: handle.mouseDown(with: event)
        case .leftMouseDragged: handle.mouseDragged(with: event)
        default: editor.step { handle.mouseUp(with: event) }
        }
    }

    /// Строки блоков `range` в колонке (координаты окна текста).
    private func area(ofBlocks range: ClosedRange<Int>, in editor: EditorFixture, shiftedBy shift: CGSize = .zero) -> NSRect {
        let textView = editor.textView
        let frames = textView.visibleBlockFrames().filter { range.contains($0.index) }.map(\.frame)
        let top = frames.map(\.lowerBound).min() ?? 0, bottom = frames.map(\.upperBound).max() ?? 0
        return NSRect(x: textView.textContainerOrigin.x + shift.width, y: top + shift.height, width: Metrics.Page.columnWidth, height: bottom - top)
    }

    @Test("Призрак — копия блока с вложенными (номер, чекбокс, текст) в 40 % цвета, едет за мышью; документ не меняется")
    func ghostFollowsPointer() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let editor = try makeEditor()
            let page = Palette.pageBackground.resolved(in: appearance)
            let group = area(ofBlocks: 1...2, in: editor)
            let before = try ViewPixels(editor.textView, appearance: appearance)
            let sourceInk = try #require(before.inkBounds(in: group, over: page))
            let sourceColor = try #require(before.strongestInkColor(in: group, over: page))

            // Вправо на ширину колонки: призрак не ложится ни на текст, ни на линию сброса.
            let start = try grip(ofBlock: 1, in: editor)
            try send(.leftMouseDown, at: start, in: editor)
            for shift in [CGSize(width: Metrics.Page.columnWidth, height: 0), CGSize(width: Metrics.Page.columnWidth, height: 25)] {
                try send(.leftMouseDragged, at: NSPoint(x: start.x + shift.width, y: start.y + shift.height), in: editor)
                let ghost = editor.textView.blockHandles.dragGhost
                #expect(!ghost.isHidden && ghost.superview === editor.textView, "\(appearance.rawValue): призрака нет")

                let pixels = try ViewPixels(editor.textView, appearance: appearance)
                let ink = try #require(pixels.inkBounds(in: group.offsetBy(dx: shift.width, dy: shift.height), over: page),
                                       "\(appearance.rawValue), сдвиг \(shift): призрак не нарисован")
                let expected = sourceInk.offsetBy(dx: shift.width, dy: shift.height)
                #expect(abs(ink.minX - expected.minX) <= 1.5 && abs(ink.maxX - expected.maxX) <= 1.5
                        && abs(ink.minY - expected.minY) <= 1.5 && abs(ink.maxY - expected.maxY) <= 1.5,
                        "\(appearance.rawValue), сдвиг \(shift): призрак \(ink), ждём \(expected) (номер, чекбокс и текст обоих блоков)")
                let color = try #require(pixels.strongestInkColor(in: ink, over: page))
                let faded = pixels.blend(NSColor(srgbRed: sourceColor.red, green: sourceColor.green, blue: sourceColor.blue, alpha: 0.4),
                                         over: Palette.pageBackground, in: appearance)
                #expect(colorDistance(color, faded) <= 0.04, "\(appearance.rawValue): цвет призрака \(color), ждём 40 % — \(faded)")
                #expect(editor.texts == ["Первый", "Пункт", "Вложенный", "Последний"], "Исходный блок до отпускания на месте")
            }
        }
    }

    @Test("Линия сброса — 4 pt, синий Notion rgba(35,131,226,0.43) в обеих темах")
    func dropIndicatorLooksLikeNotion() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let editor = try makeEditor()
            let start = try grip(ofBlock: 1, in: editor)
            try send(.leftMouseDown, at: start, in: editor)
            let last = area(ofBlocks: 3...3, in: editor)
            // Середина строки: у правого края блока место сброса — колонкой справа (US6), там линия вертикальная.
            try send(.leftMouseDragged, at: NSPoint(x: start.x + Metrics.Page.columnWidth / 2, y: last.maxY - 2), in: editor)

            let line = editor.textView.blockHandles.dropIndicator
            #expect(!line.isHidden && line.frame.height == 4, "\(appearance.rawValue): линия \(line.frame)")
            let pixels = try ViewPixels(editor.textView, appearance: appearance)
            let page = Palette.pageBackground.resolved(in: appearance)
            let color = pixels.color(at: NSPoint(x: line.frame.midX, y: line.frame.midY), over: page)
            let notion = pixels.blend(NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 0.43),
                                      over: Palette.pageBackground, in: appearance)
            #expect(colorDistance(color, notion) <= 0.02, "\(appearance.rawValue): линия \(color), ждём \(notion)")
        }
    }

    @Test("Esc отменяет перетаскивание: призрак и линия исчезают, отпускание ничего не двигает и меню не открывает")
    func escapeCancelsDrag() throws {
        let editor = try makeEditor()
        let start = try grip(ofBlock: 1, in: editor)
        let below = area(ofBlocks: 3...3, in: editor).maxY - 2
        try send(.leftMouseDown, at: start, in: editor)
        try send(.leftMouseDragged, at: NSPoint(x: start.x, y: below), in: editor)
        editor.press(#selector(NSResponder.cancelOperation(_:)))

        let handles = editor.textView.blockHandles
        #expect(handles.dragGhost.isHidden && handles.dropIndicator.isHidden, "После Esc призрак и линия скрыты")
        try send(.leftMouseDragged, at: NSPoint(x: start.x, y: below + 1), in: editor)
        #expect(handles.dragGhost.isHidden && handles.dropIndicator.isHidden, "После Esc мышь их не возвращает")
        try send(.leftMouseUp, at: NSPoint(x: start.x, y: below + 1), in: editor)
        #expect(editor.texts == ["Первый", "Пункт", "Вложенный", "Последний"])
        #expect(!editor.textView.popups.isOpen, "Отпускание после Esc — не щелчок: меню блока не открывается")
    }

    @Test("Отпускание переносит блок вместе с вложенными и убирает призрак")
    func dropMovesGroup() throws {
        let editor = try makeEditor()
        let start = try grip(ofBlock: 1, in: editor)
        let below = area(ofBlocks: 3...3, in: editor).maxY - 2
        try send(.leftMouseDown, at: start, in: editor)
        try send(.leftMouseDragged, at: NSPoint(x: start.x, y: below), in: editor)
        try send(.leftMouseUp, at: NSPoint(x: start.x, y: below), in: editor)

        #expect(editor.texts == ["Первый", "Последний", "Пункт", "Вложенный"])
        #expect(editor.indents == [0, 0, 0, 1])
        let handles = editor.textView.blockHandles
        #expect(handles.dragGhost.isHidden && handles.dropIndicator.isHidden)
    }
}
