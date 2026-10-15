import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Геометрия редактора вокруг текста по проверке интерфейса 15.10.2026 (ui-review, зона US3):
/// ручки блока, иконка страницы, курсор у подсказки.
@MainActor
@Suite("Геометрия редактора по проверке интерфейса")
struct EditorChromeGeometryTests {
    typealias Spec = EditorFixture.Spec

    @Test("Ручки «+ ⋮⋮» по середине строчных букв первой строки блока, как маркер (№ 10)")
    func handlesCenterOnFirstLine() throws {
        let specs: [Spec] = [.paragraph("Абзац текста"), .heading(1, "Заголовок"), .heading(3, "Малый"), .bullet("Пункт"), .checkbox("Задача")]
        let editor = try EditorFixture(specs)
        let textView = editor.textView
        for (index, spec) in specs.enumerated() {
            let line = try #require(textView.markerLine(ofBlockAt: index))
            textView.blockHandles.show(forBlockAt: index, line: line)
            let font = Typography.line(for: PageTextStorageMapper.textStyle(of: spec.kind)).font
            let expected = textView.textContainerOrigin.y + line.baseline - font.xHeight / 2
            let handles = textView.blockHandles.frame
            #expect(abs(handles.midY - expected) < 0.5, "\(spec.kind): середина ручек \(handles.midY), середина строчных \(expected)")
        }
    }

    @Test("Эмодзи страницы как в Notion: рисунок ≈ 61×74 по середине квадрата 78 (№ 11)")
    func pageIconMatchesNotion() throws {
        let page = Page(title: "Страница", icon: "📘", sortKey: .between(nil, nil), createdAt: Date(), updatedAt: Date())
        let header = PageHeaderView(page: page)
        header.frame = NSRect(x: 0, y: 0, width: Metrics.Page.columnWidth, height: header.height(forWidth: Metrics.Page.columnWidth))
        header.layoutSubtreeIfNeeded()
        let square = NSRect(x: 0, y: Metrics.Page.headerTopPadding, width: Metrics.Page.iconSize, height: Metrics.Page.iconSize)
        let pixels = try ViewPixels(header, appearance: .aqua)
        // Под иконкой — название: мерить только полосу иконки с запасом.
        let ink = try #require(pixels.inkBounds(in: NSRect(x: 0, y: 0, width: 200, height: square.maxY + 2)))
        #expect(ink.height >= 71 && ink.height <= 77, "Высота рисунка \(ink.height), у Notion ≈ 74")
        #expect(abs(ink.midY - square.midY) <= 3 && abs(ink.midX - square.midX) <= 3, "Рисунок \(ink) не по середине квадрата \(square)")
        #expect(ink.minY > 0.5 && ink.maxY < square.maxY + 2, "Рисунок обрезан: \(ink)")
    }

    /// Системный курсор текста шириной ≈ 2 от своей точки вправо.
    static let caretWidth: CGFloat = 2

    @Test("Подсказка под курсором начинается там же, где набранный текст того же блока (баг Юрия 15.10.2026)")
    func blockHintStartsAtText() throws {
        let specs: [Spec] = [.paragraph(""), .heading(1, ""), .heading(2, ""), .bullet(""), .checkbox("")]
        let editor = try EditorFixture([.paragraph("Выше")] + specs)
        let textView = editor.textView
        for (offset, spec) in specs.enumerated() {
            editor.placeCaret(inBlock: offset + 1)
            let hint = textView.emptyParagraphHint
            let hintText = hint.stringValue
            let ink = try #require(ViewPixels(hint, appearance: .aqua).inkBounds(in: hint.bounds))
            let filled = try EditorFixture([.paragraph("Выше"), Spec(kind: spec.kind, text: hintText)])
            let line = try #require(filled.textView.markerLine(ofBlockAt: 1))
            let origin = filled.textView.textContainerOrigin
            let row = NSRect(x: line.caretX + origin.x - 4, y: line.top + origin.y, width: 400, height: line.height)
            let text = try #require(ViewPixels(filled.textView, appearance: .aqua)
                .inkBounds(in: row, over: Palette.pageBackground.resolved(in: .aqua)))
            #expect(abs(hint.frame.minX + ink.minX - text.minX) <= 0.5,
                    "\(spec.kind): подсказка с \(hint.frame.minX + ink.minX), текст «\(hintText)» с \(text.minX)")
        }
    }

    @Test("Пустое название: курсор цвета текста, как в блоках, и не налезает на «Без названия» (№ 13)")
    func titleCaretMatchesBlocks() throws {
        let page = Page(title: "", sortKey: .between(nil, nil), createdAt: Date(), updatedAt: Date())
        let header = PageHeaderView(page: page)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        header.frame = NSRect(x: 0, y: 0, width: Metrics.Page.columnWidth, height: header.height(forWidth: Metrics.Page.columnWidth))
        window.contentView?.addSubview(header)
        let placeholder = try #require(ViewPixels(header.titleField, appearance: .aqua).inkBounds(in: header.titleField.bounds))

        header.focusTitle()
        let editor = try #require(header.titleField.currentEditor() as? NSTextView)
        #expect(editor.insertionPointColor == Palette.textPrimary, "Курсор названия \(editor.insertionPointColor)")
        let caret = header.titleField.convert(window.convertFromScreen(
            editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)), from: nil)
        let gap = placeholder.minX - (caret.minX + Self.caretWidth)
        #expect(gap >= 1 && gap <= 3.5, "От курсора до «Без названия» \(gap)")
    }
}
