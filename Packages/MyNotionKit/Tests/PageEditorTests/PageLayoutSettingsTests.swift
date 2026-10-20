import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Вид страницы (research R2; contracts/pages-ui.md, «Вид страницы»): широкая страница — колонка во всю ширину области
/// страницы минус поля 96; мелкий шрифт — текст блоков, код и колонки × 14/16, название страницы не меняется.
/// Переключение — без пересоздания редактора; новый текст набирается тем же размером.
@MainActor
@Suite("Вид страницы: ширина и мелкий шрифт")
struct PageLayoutSettingsTests {
    typealias Spec = EditorFixture.Spec

    @Test("Колонка обычной и широкой страницы при ширине области 900, 1200, 1800",
          arguments: [(900, 96, 708, 708), (1200, 240, 720, 1008), (1800, 540, 720, 1608)] as [(CGFloat, CGFloat, CGFloat, CGFloat)])
    func columnWidths(width: CGFloat, normalLeft: CGFloat, normalWidth: CGFloat, wideWidth: CGFloat) {
        let normal = PageLayoutSettings().column(pageWidth: width, textWidth: width)
        #expect(normal.left == normalLeft)
        #expect(normal.width == normalWidth)
        let wide = PageLayoutSettings(isFullWidth: true).column(pageWidth: width, textWidth: width)
        #expect(wide.left == Metrics.Page.minimumSideInset)
        #expect(wide.width == wideWidth)
    }

    private func font(_ editor: EditorFixture, block index: Int) throws -> NSFont {
        let location = editor.textLocation(ofBlock: index)
        return try #require(editor.textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
    }

    private func lineHeight(_ editor: EditorFixture, block index: Int) throws -> CGFloat {
        let location = editor.textLocation(ofBlock: index)
        let style = try #require(editor.textView.textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)
        return style.minimumLineHeight
    }

    @Test("Мелкий шрифт: абзац 14 / 21, заголовки × 14/16; название — 40; обратно — как было")
    func smallTextScale() throws {
        let editor = try EditorFixture([.paragraph("Абзац"), .heading(1, "Один"), .heading(2, "Два"), .heading(3, "Три"),
                                        .bullet("Пункт")])
        let textView = editor.textView
        textView.applyLayout(PageLayoutSettings(isSmallText: true))

        #expect(try font(editor, block: 0).pointSize == 14)
        #expect(try lineHeight(editor, block: 0) == 21)
        #expect(try font(editor, block: 1).pointSize == 30 * 14 / 16)
        #expect(try font(editor, block: 2).pointSize == 24 * 14 / 16)
        #expect(try font(editor, block: 3).pointSize == 20 * 14 / 16)
        #expect(try font(editor, block: 4).pointSize == 14)
        #expect(textView.header.titleField.font?.pointSize == 40)

        textView.applyLayout(PageLayoutSettings())
        #expect(try font(editor, block: 0).pointSize == 16)
        #expect(try lineHeight(editor, block: 0) == 24)
        #expect(try font(editor, block: 1).pointSize == 30)
    }

    @Test("Мелкий шрифт: новый блок после Enter и набранный текст — тоже 14; смена типа блока не возвращает 16")
    func newTextKeepsSmallScale() throws {
        let editor = try EditorFixture([.paragraph("Абзац")])
        editor.textView.applyLayout(PageLayoutSettings(isSmallText: true))
        editor.placeCaret(inBlock: 0, at: nil)
        editor.press(#selector(NSResponder.insertNewline(_:)))
        editor.type("Новый")
        #expect(editor.document.blocks.map(\.text.string) == ["Абзац", "Новый"])
        #expect(try font(editor, block: 1).pointSize == 14)
        #expect((editor.textView.typingAttributes[.font] as? NSFont)?.pointSize == 14)

        editor.type("# ")
        editor.placeCaret(inBlock: 1, at: 0)
        editor.type("## ")
        #expect(editor.document.blocks[1].kind == .heading2)
        #expect(try font(editor, block: 1).pointSize == 24 * 14 / 16)
    }

    @Test("Страница с мелким шрифтом открывается сразу мелкой: колонка, высота строк и код — × 14/16")
    func openSmallPage() throws {
        let editor = try EditorFixture([.paragraph("Абзац"), Spec(kind: .code, text: "let x = 1")])
        let textView = editor.textView
        textView.applyLayout(PageLayoutSettings(isSmallText: true))
        #expect(try font(editor, block: 0).pointSize == 14)
        let factory = try #require(BlockViewFactories.shared.factory(for: .code))
        let block = editor.document.blocks[1]
        let context = BlockViewContext(textView: textView, width: 720)
        let code = try #require(factory.makeView(for: block, context: context) as? CodeBlockView)
        #expect(code.textView.font?.pointSize == CodeBlockStyle.fontSize * 14 / 16)
        let small = try #require(factory.height(for: block, width: 720, context: context))
        let normal = try #require(factory.height(for: block, width: 720))
        #expect(small < normal)

        textView.applyLayout(PageLayoutSettings())
        #expect(code.textView.font?.pointSize == CodeBlockStyle.fontSize)
    }

    @Test("Колонки 002: текст в колонках — × 14/16 и следует за переключением")
    func columnsFollowScale() throws {
        let editor = try EditorFixture([.paragraph("P1"), .paragraph("L1"), .paragraph("R1")])
        let ids = editor.document.blocks.map(\.id)
        editor.step { editor.textView.placeBlocks([ids[2]], besideRightOf: ids[1]) }
        let list = try #require(editor.document.blocks.first { $0.kind == .columnList }).id
        editor.layoutViewport()
        editor.textView.applyLayout(PageLayoutSettings(isSmallText: true))
        let columns = editor.textView.flowEditors(inColumnList: list)
        #expect(columns.count == 2)
        for column in columns {
            let font = column.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.pointSize == 14)
        }
        editor.textView.applyLayout(PageLayoutSettings())
        for column in columns {
            let font = column.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.pointSize == 16)
        }
    }

    @Test("Широкая: колонка текста и шапка — во всю ширину минус 96 с каждой стороны; редактор тот же")
    func wideColumnInEditor() throws {
        let editor = try EditorFixture([.paragraph("Абзац")])
        let textView = editor.textView
        let before = ObjectIdentifier(textView)
        textView.applyLayout(PageLayoutSettings(isFullWidth: true))
        #expect(textView.textContainer?.size.width == textView.bounds.width - 2 * Metrics.Page.minimumSideInset)
        #expect(textView.header.frame.minX == Metrics.Page.minimumSideInset)
        #expect(ObjectIdentifier(editor.textView) == before)
    }
}
