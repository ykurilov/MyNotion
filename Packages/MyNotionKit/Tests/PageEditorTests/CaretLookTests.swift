import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Курсор как в Notion (снимок Юрия 15.10.2026): ширина 1, высота — от верха до низа букв шрифта строки
/// (у текста 16 это ≈ 18,8, а не вся строка 24), цвет текста, на букву не налезает.
@MainActor
@Suite("Курсор как в Notion")
struct CaretLookTests {
    static let text = "Блок текстом"

    private func makeEditor(_ spec: EditorFixture.Spec) throws -> EditorFixture {
        let editor = try EditorFixture([spec, .paragraph("Ниже")])
        editor.textView.caret.showsWithoutKeyWindow = true
        return editor
    }

    /// Курсор у места `offset` в блоке 0 и нарисованное рядом без курсора.
    private func caret(at offset: Int, in editor: EditorFixture, appearance: NSAppearance.Name = .darkAqua) throws -> (rect: NSRect, letters: ViewPixels) {
        editor.placeCaret(inBlock: 0, at: offset)
        let caret = editor.textView.caret
        #expect(caret.isShown, "Курсор не показан")
        let rect = caret.frame
        // Снимок букв без курсора: в неключевом окне курсора нет.
        caret.showsWithoutKeyWindow = false
        caret.update()
        defer { caret.showsWithoutKeyWindow = true }
        return (rect, try ViewPixels(editor.textView, appearance: appearance))
    }

    @Test("Ширина 1, высота от верха до низа букв шрифта, по базовой линии строки — во всех типах блоков",
          arguments: [BlockKind.paragraph, .heading1, .heading2, .heading3, .bulletItem, .numberedItem, .checkbox])
    func caretFitsFont(_ kind: BlockKind) throws {
        let spec = EditorFixture.Spec(kind: kind, text: Self.text)
        let editor = try makeEditor(spec)
        let font = Typography.line(for: PageTextStorageMapper.textStyle(of: spec.kind)).font
        let line = try #require(editor.textView.markerLine(ofBlockAt: 0))
        let origin = editor.textView.textContainerOrigin
        let baseline = origin.y + line.baseline
        let (rect, _) = try caret(at: 0, in: editor)
        #expect(rect.width == Metrics.Caret.width, "\(spec.kind): ширина \(rect.width)")
        #expect(abs(rect.height - (font.ascender - font.descender)) <= 0.5, "\(spec.kind): высота \(rect.height), шрифт \(font.ascender - font.descender)")
        #expect(abs(rect.minY - (baseline - font.ascender)) <= 0.5, "\(spec.kind): верх \(rect.minY), ждём \(baseline - font.ascender)")
        let textStart = line.caretX + origin.x
        #expect(rect.minX >= textStart - 1 && rect.minX <= textStart, "\(spec.kind): курсор с \(rect.minX), текст с \(textStart)")
    }

    /// Просвет между буквами у курсора по снимку без курсора: столбцы пикселей на высоте курсора без чёткой краски буквы,
    /// ближайшие к середине курсора.
    private func letterGap(around caret: NSRect, in letters: ViewPixels) -> ClosedRange<CGFloat>? {
        let page = Palette.pageBackground.resolved(in: .darkAqua)
        let step: CGFloat = 0.5
        // Насколько чётко закрашен столбец: наибольшая разница с фоном.
        let columns = stride(from: caret.minX - 3, to: caret.maxX + 3, by: step).map { x in
            let ink = letters.strongestInkColor(in: NSRect(x: x, y: caret.minY, width: step, height: caret.height), over: page)
            return (x: x, ink: ink.map { colorDistance($0, page) } ?? 0)
        }
        var runs: [ClosedRange<CGFloat>] = []
        for column in columns where column.ink <= 0.5 {
            if let last = runs.last, abs(last.upperBound - column.x) < 0.01 {
                runs[runs.count - 1] = last.lowerBound...column.x + step
            } else {
                runs.append(column.x...column.x + step)
            }
        }
        // Буквы сходятся без просвета (кернинг): «просвет» — самый бледный столбец между ними.
        let middle = columns.filter { abs($0.x + step / 2 - caret.midX) <= 1.5 }
        guard !runs.isEmpty else { return middle.min { $0.ink < $1.ink }.map { $0.x...$0.x + step } }
        return runs.min { abs(($0.lowerBound + $0.upperBound) / 2 - caret.midX) < abs(($1.lowerBound + $1.upperBound) / 2 - caret.midX) }
    }

    @Test("Курсор не налезает на буквы: в начале строки не касается, внутри слова — в просвете, а в узком — по его середине",
          arguments: [BlockKind.paragraph, .heading1, .numberedItem])
    func caretClearsLetters(_ kind: BlockKind) throws {
        let spec = EditorFixture.Spec(kind: kind, text: Self.text)
        let editor = try makeEditor(spec)
        let page = Palette.pageBackground.resolved(in: .darkAqua)
        let (start, startLetters) = try caret(at: 0, in: editor)
        let touching = startLetters.inkBounds(in: start, over: page, threshold: 0.25)
        #expect(touching == nil, "\(kind): курсор \(start) в начале строки касается буквы \(String(describing: touching))")
        for offset in [1, 2, 3, 6, 7, 8, 9, 10, 11] {
            let (rect, letters) = try caret(at: offset, in: editor)
            let gap = try #require(letterGap(around: rect, in: letters), "\(kind), место \(offset): нет просвета у курсора \(rect)")
            if gap.upperBound - gap.lowerBound >= rect.width {
                #expect(rect.minX >= gap.lowerBound && rect.maxX <= gap.upperBound, "\(kind), место \(offset): курсор \(rect) вне просвета \(gap)")
            } else {
                #expect(abs(rect.midX - (gap.lowerBound + gap.upperBound) / 2) <= 0.5, "\(kind), место \(offset): курсор \(rect) не посередине узкого просвета \(gap)")
            }
        }
    }

    @Test("Цвет курсора — цвет текста в обеих темах")
    func caretColor() throws {
        let editor = try makeEditor(.paragraph(Self.text))
        editor.placeCaret(inBlock: 0, at: 4)
        let rect = editor.textView.caret.frame
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let pixels = try ViewPixels(editor.textView, appearance: appearance)
            let color = try #require(pixels.strongestInkColor(in: rect, over: Palette.pageBackground.resolved(in: appearance)))
            // Эталон смешан так же, как снимок: в его цветовом пространстве.
            let text = pixels.blend(Palette.textPrimary, over: Palette.pageBackground, in: appearance)
            #expect(colorDistance(color, text) <= 0.02, "\(appearance.rawValue): курсор \(color), текст \(text)")
        }
    }

    @Test("Пустой пункт в конце страницы: курсор там, где начнётся текст, а не у края колонки")
    func caretInEmptyLastItem() throws {
        let editor = try EditorFixture([.bullet("Пункт"), .bullet("")])
        editor.textView.caret.showsWithoutKeyWindow = true
        editor.placeCaret(inBlock: 1)
        let line = try #require(editor.textView.markerLine(ofBlockAt: 1))
        let textStart = line.caretX + editor.textView.textContainerOrigin.x
        let rect = editor.textView.caret.frame
        #expect(rect.minX >= textStart - 1 && rect.minX <= textStart, "Курсор с \(rect.minX), текст с \(textStart)")
    }

    @Test("С выделением курсора нет; снятое выделение возвращает курсор")
    func caretHidesWithSelection() throws {
        let editor = try makeEditor(.paragraph(Self.text))
        editor.select(inBlock: 0, "Блок")
        #expect(!editor.textView.caret.isShown)
        editor.placeCaret(inBlock: 0, at: 2)
        #expect(editor.textView.caret.isShown)
    }

    @Test("Мигает: погас — набор и перемещение зажигают снова")
    func caretBlinks() throws {
        let editor = try makeEditor(.paragraph(Self.text))
        editor.placeCaret(inBlock: 0, at: 2)
        let caret = editor.textView.caret
        caret.blink()
        #expect(!caret.isShown, "После такта мигания курсор погас")
        editor.type("ы")
        #expect(caret.isShown, "Набор зажигает курсор")
    }

    @Test("Фокус ушёл в название — курсор и выделение в тексте гаснут: курсор один на окно")
    func caretLeavesWithFocus() throws {
        let editor = try makeEditor(.paragraph(Self.text))
        editor.placeCaret(inBlock: 0, at: 2)
        #expect(editor.textView.caret.isShown)
        editor.textView.header.layoutSubtreeIfNeeded()
        editor.textView.header.focusTitle()
        #expect(!editor.textView.caret.isShown, "Курсор в тексте остался гореть рядом с курсором названия")
        let titleEditor = try #require(editor.textView.header.titleField.currentEditor() as? PageTitleEditor)
        titleEditor.caret.showsWithoutKeyWindow = true
        titleEditor.caret.update()
        #expect(titleEditor.caret.isShown)
        editor.textView.window?.makeFirstResponder(editor.textView)
        editor.placeCaret(inBlock: 0, at: 2)
        #expect(!titleEditor.caret.isShown, "Курсор названия остался гореть после возврата в текст")
        editor.select(inBlock: 0, "Блок")
        #expect(!editor.textView.selectionHighlightRects().isEmpty)
        editor.textView.header.focusTitle()
        #expect(editor.textView.drawnSelectionRects.isEmpty, "Выделение в тексте осталось подсвеченным без фокуса")
    }

    @Test("Курсор в названии: ширина 1, высота по шрифту названия, на букву не налезает")
    func titleCaret() throws {
        let editor = try makeEditor(.paragraph(Self.text))
        let header = editor.textView.header
        header.layoutSubtreeIfNeeded()
        header.focusTitle()
        let titleEditor = try #require(header.titleField.currentEditor() as? PageTitleEditor, "Название правится не своим редактором")
        titleEditor.caret.showsWithoutKeyWindow = true
        titleEditor.setSelectedRange(NSRange(location: 0, length: 0))
        let caret = titleEditor.caret
        #expect(caret.isShown)
        let font = Typography.pageTitle.font
        #expect(caret.frame.width == Metrics.Caret.width && abs(caret.frame.height - (font.ascender - font.descender)) <= 0.5,
                "Курсор названия \(caret.frame)")
        let rect = caret.frame
        caret.showsWithoutKeyWindow = false
        caret.update()
        // Редактор названия без своего фона: буквы — непрозрачные точки.
        let pixels = try ViewPixels(titleEditor, appearance: .darkAqua)
        let ink = pixels.inkBounds(in: rect, threshold: 0.25)
        #expect(ink == nil, "Курсор названия налезает на букву: \(String(describing: ink))")
        let letters = try #require(pixels.inkBounds(in: titleEditor.bounds))
        // Сверху курсор — на высоте верха шрифта: над заглавными буквами, как у Notion.
        #expect(rect.minY < letters.minY && rect.maxY > letters.minY + font.capHeight, "Курсор \(rect), буквы \(letters)")
    }
}
