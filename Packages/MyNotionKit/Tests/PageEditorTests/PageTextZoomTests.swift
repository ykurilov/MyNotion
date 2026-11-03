import AppKit
import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Масштаб текста страниц (⌘+, ⌘−, ⌘0): общий для приложения, хранится в настройках, а не в странице; складывается
/// с «мелким шрифтом». Меняет текст, заголовки, название, код и колонки; курсор, прокрутку и ⌘Z не трогает.
@MainActor
@Suite("Масштаб текста страниц")
struct PageTextZoomTests {
    typealias Spec = EditorFixture.Spec

    /// Своё хранилище настроек на тест: общий масштаб приложения тесты не трогают.
    private func isolatedDefaults() -> UserDefaults {
        let name = "PageTextZoomTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Шаги и хранение

    @Test("⌘+ идёт по шагам до 200 %, ⌘− — до 75 %, ⌘0 — обратно 100 %")
    func steps() {
        let zoom = PageTextZoom(defaults: isolatedDefaults())
        #expect(zoom.scale == 1)
        #expect(zoom.isActualSize)
        var upward: [CGFloat] = []
        while zoom.canZoomIn { zoom.zoomIn(); upward.append(zoom.scale) }
        #expect(upward == [1.15, 1.25, 1.5, 1.75, 2])
        zoom.zoomIn()
        #expect(zoom.scale == 2)

        zoom.reset()
        #expect(zoom.scale == 1)
        var downward: [CGFloat] = []
        while zoom.canZoomOut { zoom.zoomOut(); downward.append(zoom.scale) }
        #expect(downward == [0.85, 0.75])
        zoom.zoomOut()
        #expect(zoom.scale == 0.75)
        #expect(!zoom.isActualSize)
    }

    @Test("Масштаб сохраняется в настройках и читается новым запуском; чужое число — ближайший шаг")
    func persists() {
        let defaults = isolatedDefaults()
        let zoom = PageTextZoom(defaults: defaults)
        zoom.zoomIn()
        zoom.zoomIn()
        #expect(PageTextZoom(defaults: defaults).scale == 1.25)

        defaults.set(9.0, forKey: PageTextZoom.defaultsKey)
        #expect(PageTextZoom(defaults: defaults).scale == 2)
        defaults.set(1.23, forKey: PageTextZoom.defaultsKey)
        #expect(PageTextZoom(defaults: defaults).scale == 1.25)
    }

    @Test("Смена масштаба оповещает; повтор на краю — нет")
    func notifiesOnlyOnChange() {
        let zoom = PageTextZoom(defaults: isolatedDefaults())
        var count = 0
        let observer = NotificationCenter.default.addObserver(forName: PageTextZoom.didChange, object: zoom, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        zoom.zoomOut()
        zoom.zoomOut()
        zoom.zoomOut()
        zoom.reset()
        zoom.reset()
        #expect(count == 3)
    }

    @Test("Масштаб складывается с мелким шрифтом")
    func combinesWithSmallText() {
        #expect(PageLayoutSettings(textZoom: 1.5).fontScale == 1.5)
        #expect(PageLayoutSettings(isSmallText: true, textZoom: 1.5).fontScale == PageLayoutSettings.smallTextScale * 1.5)
        #expect(PageLayoutSettings(isSmallText: true).fontScale == PageLayoutSettings.smallTextScale)
    }

    // MARK: Редактор

    private func font(_ editor: EditorFixture, block index: Int) throws -> NSFont {
        let location = editor.textLocation(ofBlock: index)
        return try #require(editor.textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
    }

    private func paragraphStyle(_ editor: EditorFixture, block index: Int) throws -> NSParagraphStyle {
        let location = editor.textLocation(ofBlock: index)
        return try #require(editor.textView.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
    }

    private func zoomed(_ editor: EditorFixture, _ scale: CGFloat) {
        var settings = editor.textView.layoutSettings
        settings.textZoom = scale
        editor.textView.applyLayout(settings)
    }

    @Test("150 %: абзац 24 / 36, заголовки и отступы × 1,5, название 60, код × 1,5; ⌘0 — как было")
    func editorScales() throws {
        let editor = try EditorFixture([.paragraph("Абзац"), .heading(1, "Один"), .heading(2, "Два"),
                                        Spec(kind: .code, text: "let x = 1")])
        let textView = editor.textView
        let spacingBefore = try paragraphStyle(editor, block: 1).paragraphSpacingBefore
        let factory = try #require(BlockViewFactories.shared.factory(for: .code))
        let context = BlockViewContext(textView: textView, width: 720)
        let code = try #require(factory.makeView(for: editor.document.blocks[3], context: context) as? CodeBlockView)

        zoomed(editor, 1.5)
        #expect(try font(editor, block: 0).pointSize == 24)
        #expect(try paragraphStyle(editor, block: 0).minimumLineHeight == 36)
        #expect(try font(editor, block: 1).pointSize == 45)
        #expect(try font(editor, block: 2).pointSize == 36)
        #expect(try paragraphStyle(editor, block: 1).paragraphSpacingBefore == spacingBefore * 1.5)
        #expect(textView.header.titleField.font?.pointSize == 60)
        #expect(code.textView.font?.pointSize == CodeBlockStyle.fontSize * 1.5)

        zoomed(editor, 1)
        #expect(try font(editor, block: 0).pointSize == 16)
        #expect(try font(editor, block: 1).pointSize == 30)
        #expect(textView.header.titleField.font?.pointSize == 40)
        #expect(code.textView.font?.pointSize == CodeBlockStyle.fontSize)
    }

    @Test("Мелкий шрифт страницы при 125 %: абзац 17,5; название — 50, мелкий шрифт его не меняет")
    func smallTextAndZoom() throws {
        let editor = try EditorFixture([.paragraph("Абзац")])
        editor.textView.applyLayout(PageLayoutSettings(isSmallText: true, textZoom: 1.25))
        #expect(try font(editor, block: 0).pointSize == 14 * 1.25)
        #expect(editor.textView.header.titleField.font?.pointSize == 50)
    }

    @Test("Смена вида страницы (мелкий шрифт из меню, другое устройство) масштаб не сбрасывает")
    func pageAppearanceKeepsZoom() throws {
        let editor = try EditorFixture([.paragraph("Абзац")])
        zoomed(editor, 1.5)
        var page = editor.document.page
        page.isSmallText = true
        editor.textView.showAppearance(of: page)
        #expect(editor.textView.layoutSettings.textZoom == 1.5)
        #expect(try font(editor, block: 0).pointSize == 14 * 1.5)
    }

    @Test("Открытый редактор следует за масштабом приложения: текст, название и колонки")
    func openEditorFollowsZoom() throws {
        let editor = try EditorFixture([.paragraph("P1"), .paragraph("L1"), .paragraph("R1")])
        let ids = editor.document.blocks.map(\.id)
        editor.step { editor.textView.placeBlocks([ids[2]], besideRightOf: ids[1]) }
        let list = try #require(editor.document.blocks.first { $0.kind == .columnList }).id
        editor.layoutViewport()

        let zoom = PageTextZoom(defaults: isolatedDefaults())
        editor.textView.textZoom = zoom
        // Чужой масштаб (другого окна приложения или пробы) редактор не трогает.
        PageTextZoom(defaults: isolatedDefaults()).zoomOut()
        #expect(editor.textView.layoutSettings.textZoom == 1)
        zoom.zoomIn()
        zoom.zoomIn()
        #expect(editor.textView.layoutSettings.textZoom == 1.25)
        #expect(try font(editor, block: 0).pointSize == 20)
        #expect(editor.textView.header.titleField.font?.pointSize == 50)
        for column in editor.textView.flowEditors(inColumnList: list) {
            let font = column.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.pointSize == 20)
        }
    }

    @Test("Набранный при 150 % текст и новый блок — тоже 24")
    func typingKeepsZoom() throws {
        let editor = try EditorFixture([.paragraph("Абзац")])
        zoomed(editor, 1.5)
        editor.placeCaret(inBlock: 0, at: nil)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        editor.type("Новый")
        #expect(editor.texts == ["Абзац", "Новый"])
        #expect(try font(editor, block: 1).pointSize == 24)
    }

    @Test("Смена масштаба — не правка: ⌘Z отменяет прежнюю правку, вернувшийся текст — в новом размере")
    func undoIgnoresZoom() throws {
        let editor = try EditorFixture([.paragraph("Один два")])
        editor.select(inBlock: 0, " два")
        editor.press(#selector(NSResponder.deleteBackward(_:)))
        #expect(editor.texts == ["Один"])

        zoomed(editor, 1.5)
        editor.undo()
        #expect(editor.texts == ["Один два"])
        let storage = try #require(editor.textView.textStorage)
        var sizes = Set<CGFloat>()
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length - 1)) { value, _, _ in
            if let font = value as? NSFont { sizes.insert(font.pointSize) }
        }
        #expect(sizes == [24])
        #expect(try editor.savedBlocks().map(\.text.string) == ["Один два"])
    }

    @Test("Курсор и место прокрутки остаются на месте")
    func keepsCaretAndScroll() throws {
        let editor = try EditorFixture((0..<300).map { .paragraph("Абзац номер \($0): немного текста, чтобы строка была похожа на настоящую.") })
        let textView = editor.textView
        let scrollView = try #require(textView.enclosingScrollView)
        textView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 3_000))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        editor.window.displayIfNeeded()
        editor.layoutViewport()
        // Курсор — в видимый блок под верхним: место прокрутки от него не меняется.
        let top = try #require(textView.scrollPlace())
        editor.placeCaret(inBlock: try #require(editor.document.index(ofBlock: top.blockId)) + 3, at: 5)
        let caret = textView.selectedRange()
        editor.layoutViewport()
        let before = try #require(textView.scrollPlace())

        zoomed(editor, 1.5)
        textView.layoutSubtreeIfNeeded()
        let after = try #require(textView.scrollPlace())
        #expect(after.blockId == before.blockId)
        #expect(abs(after.offset - before.offset * 1.5) < 2)
        #expect(textView.selectedRange() == caret)

        zoomed(editor, 0.75)
        textView.layoutSubtreeIfNeeded()
        #expect(textView.scrollPlace()?.blockId == before.blockId)
        #expect(textView.selectedRange() == caret)
    }
}
