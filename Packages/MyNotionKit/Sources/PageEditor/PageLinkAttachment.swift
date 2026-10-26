import AppKit
import CoreText
import NotesCore
import VisualStyle

/// Страница, на которую ссылается блок-подстраница: что показать в строке блока.
public struct LinkedPage: Sendable, Hashable {
    public var title: String
    public var icon: String?

    public init(title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
    }

    /// Название для показа: пустое — «Без названия».
    var displayTitle: String { title.isEmpty ? Page.untitledTitle : title }
}

/// Строка блока-подстраницы: значок или эмодзи страницы и подчёркнутое название (contracts/visual-style.md, «Блоки»).
/// Текста у блока нет: строку целиком рисует фрагмент, щелчок по ней открывает страницу. Страницы нет — как у
/// упоминания: серое зачёркнутое «Удалённая страница» (стёрта, в корзине) или серое «Страница загружается».
@MainActor
enum PageLinkPainter {
    static var titleFont: NSFont { Typography.pageLinkTitle.font }

    static func draw(_ shown: MentionDisplay, column: CGRect, textStart: CGFloat, baseline: CGFloat, maxX: CGFloat) {
        drawIcon(shown.icon, in: column, centerY: baseline - titleFont.capHeight / 2)
        let isPage = shown.state == .page
        let color = !isPage || shown.title == Page.untitledTitle ? Palette.textSecondary : Palette.textPrimary
        let line = truncatedLine(shown.title, width: max(0, maxX - textStart))
        BlockDecorationPainter.drawLine(line, color: color, baselineOrigin: CGPoint(x: textStart, y: baseline))

        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        switch shown.state {
        case .page:
            let underline = CGRect(x: textStart, y: baseline + Metrics.PageLinkBlock.underlineOffset,
                                   width: width, height: Metrics.PageLinkBlock.underlineThickness)
            Palette.border.setFill()
            underline.fill()
        case .deleted:
            let strike = CGRect(x: textStart, y: (baseline - titleFont.xHeight / 2).rounded(),
                                width: width, height: Metrics.PageLinkBlock.underlineThickness)
            Palette.textSecondary.setFill()
            strike.fill()
        case .loading:
            break
        }
    }

    /// Эмодзи страницы или значок документа по центру колонки маркера, на высоте середины заглавных букв названия.
    private static func drawIcon(_ icon: String?, in column: CGRect, centerY: CGFloat) {
        let size = Metrics.PageLinkBlock.iconSize
        let box = CGRect(x: column.midX - size / 2, y: centerY - size / 2, width: size, height: size)
        if let icon, !icon.isEmpty {
            let font = NSFont.systemFont(ofSize: size * 0.85)
            let string = NSAttributedString(string: icon, attributes: [.font: font])
            let measured = string.size()
            string.draw(at: CGPoint(x: box.midX - measured.width / 2, y: box.midY - measured.height / 2))
            return
        }
        // Тот же пустой лист, что у страницы без иконки в дереве слева.
        DocumentGlyph.image(size: size, color: Palette.textSecondary).draw(in: box)
    }

    static func truncatedLine(_ title: String, width: CGFloat) -> CTLine {
        let line = BlockDecorationPainter.textLine(title, font: titleFont)
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > width else { return line }
        let ellipsis = BlockDecorationPainter.textLine("…", font: titleFont)
        return CTLineCreateTruncatedLine(line, Double(width), .end, ellipsis) ?? line
    }
}

extension PageTextView {
    /// Страница блока-подстраницы под точкой (координаты окна текста).
    func linkedPage(at point: NSPoint) -> UUID? {
        guard let (index, line) = markerLineNear(point) else { return nil }
        let block = document.blocks[index]
        guard block.kind == .pageLink, let pageId = block.linkedPageId else { return nil }
        let origin = textContainerOrigin
        let column = line.markerColumn.offsetBy(dx: origin.x, dy: origin.y)
        // Вся подсвеченная строка, а не только название: текста для ввода у блока нет.
        let width = origin.x + (textContainer?.size.width ?? Metrics.Page.columnWidth) - column.minX
        let target = CGRect(x: column.minX, y: column.minY, width: width, height: column.height)
        return target.contains(point) ? pageId : nil
    }
}

extension PageTextView {
    /// Что показать в строке блока-подстраницы: страница из дерева или, если её нет, — как упоминание.
    func pageLinkDisplay(of pageId: UUID?) -> MentionDisplay {
        guard let pageId else { return MentionDisplay(title: Page.untitledTitle, icon: nil, state: .page) }
        if let page = linkedPages[pageId] { return MentionDisplay(title: page.displayTitle, icon: page.icon, state: .page) }
        return mentionDirectory.display(of: pageId)
    }
}
