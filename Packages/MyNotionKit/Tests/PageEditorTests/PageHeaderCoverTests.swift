import AppKit
import Testing
@testable import NotesCore
@testable import PageEditor
import VisualStyle

/// Шапка с обложкой (contracts/pages-ui.md, «Шапка страницы»): обложка во всю ширину над шапкой; иконка заходит
/// на неё серединой на нижний край; без иконки строка кнопок и название — под обложкой, как у Notion.
@MainActor
@Suite("Шапка с обложкой")
struct PageHeaderCoverTests {
    @Test("Обложка — во всю ширину сверху; середина иконки на нижнем крае обложки; текст ниже названия")
    func iconOverlapsCover() throws {
        let editor = try EditorFixture([.paragraph("Текст")], icon: "📘")
        let textView = editor.textView
        textView.header.layoutSubtreeIfNeeded()
        let titleWithoutCover = textView.header.convert(textView.header.titleField.frame, to: textView).minY
        let cover = NSView()
        var columns: [(CGFloat, CGFloat)] = []
        textView.setCover(cover, height: 200) { columns.append(($0, $1)) }
        textView.header.layoutSubtreeIfNeeded()

        #expect(cover.frame == NSRect(x: 0, y: 0, width: textView.bounds.width, height: 200))
        let icon = textView.header.convert(textView.header.iconView.frame, to: textView)
        #expect(icon.midY == 200)
        let title = textView.header.convert(textView.header.titleField.frame, to: textView)
        #expect(title.minY == icon.maxY + Metrics.Page.iconToTitleSpacing)
        #expect(textView.textContainerOrigin.y >= title.maxY)
        #expect(columns.last.map { $0.0 == textView.column.left && $0.1 == textView.column.width } == true)
        // Обложка выше иконки: иконка рисуется поверх.
        let order = textView.subviews
        #expect(try #require(order.firstIndex(of: cover)) < #require(order.firstIndex(of: textView.header)))

        textView.setCover(nil, height: 0)
        textView.header.layoutSubtreeIfNeeded()
        #expect(cover.superview == nil)
        #expect(textView.header.convert(textView.header.titleField.frame, to: textView).minY == titleWithoutCover)
    }

    @Test("Без иконки: строка кнопок и название — под обложкой с полем как у Notion")
    func coverWithoutIcon() throws {
        let editor = try EditorFixture([.paragraph("Текст")])
        let textView = editor.textView
        textView.setCover(NSView(), height: 180)
        textView.header.layoutSubtreeIfNeeded()
        let title = textView.header.convert(textView.header.titleField.frame, to: textView)
        #expect(title.minY == 180 + Metrics.Page.headerTopPaddingWithCover)
        textView.header.isHovered = true
        textView.header.layoutSubtreeIfNeeded()
        let button = textView.header.convert(textView.header.addIconButton.frame, to: textView)
        #expect(button.minY > 180)
    }

    @Test("Кнопка «Добавить обложку» встаёт в строку кнопок за «Добавить иконку» и прячется, когда недоступна")
    func addCoverButton() throws {
        let editor = try EditorFixture([.paragraph("Текст")])
        let header = editor.textView.header
        let addCover = PageHeaderButton(symbolName: "photo", title: "Добавить обложку", identifier: "add-page-cover")
        header.addButton(addCover)
        header.isHovered = true
        header.layoutSubtreeIfNeeded()
        #expect(!addCover.isHidden)
        #expect(addCover.frame.minX > header.addIconButton.frame.maxX)
        #expect(addCover.frame.minY == header.addIconButton.frame.minY)
        addCover.isAvailable = false
        #expect(addCover.isHidden)
    }

    @Test("Вид страницы из документа: обложка и флаги приходят в редактор через showAppearance")
    func showAppearanceAppliesLayout() throws {
        let editor = try EditorFixture([.paragraph("Текст")])
        var page = editor.document.page
        page.isFullWidth = true
        page.isSmallText = true
        editor.textView.showAppearance(of: page)
        #expect(editor.textView.layoutSettings == PageLayoutSettings(isFullWidth: true, isSmallText: true))
    }
}
