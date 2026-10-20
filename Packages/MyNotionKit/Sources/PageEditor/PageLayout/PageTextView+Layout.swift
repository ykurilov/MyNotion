import AppKit

/// Место обложки над шапкой: вид во всю ширину области страницы и его высота (contracts/pages-ui.md, «Шапка»).
@MainActor
final class CoverSlot {
    var view: NSView?
    var height: CGFloat = 0
}

extension PageTextView {
    /// Поставить вид обложки над шапкой (`nil` — убрать); текст и шапка сдвигаются вниз на `height`.
    public func setCover(_ view: NSView?, height: CGFloat) {
        if coverSlot.view !== view {
            coverSlot.view?.removeFromSuperview()
            if let view { addSubview(view, positioned: .below, relativeTo: header) }
            coverSlot.view = view
        }
        coverSlot.height = view == nil ? 0 : height
        layoutColumn()
    }

    /// Вид в месте «под названием» шапки (US5: строка обратных ссылок); `nil` — место пустое и высоты не занимает.
    public func setUnderTitle(_ view: NSView?, height: CGFloat) {
        header.setUnderTitle(view, height: height)
        layoutColumn()
    }

    /// Сменить вид страницы без пересоздания редактора: ширина колонки — сразу, шрифты текста — на месте, в тех же
    /// атрибутах (виды 002 не пересоздаются). Черновик этапа 0 (проба T003): шкала видов 002 и набора — в US1.
    public func applyLayout(_ settings: PageLayoutSettings) {
        guard settings != layoutSettings else { return }
        let ratio = settings.fontScale / layoutSettings.fontScale
        layoutSettings = settings
        if ratio != 1, let textStorage { Self.rescale(textStorage, by: ratio) }
        layoutColumn()
        needsLayout = true
        needsDisplay = true
    }

    /// Шрифты и высоты строк текста × `ratio`; отступы вложенности не меняются.
    static func rescale(_ textStorage: NSTextStorage, by ratio: CGFloat) {
        let whole = NSRange(location: 0, length: textStorage.length)
        textStorage.beginEditing()
        textStorage.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? NSFont else { return }
            textStorage.addAttribute(.font, value: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * ratio) ?? font, range: range)
        }
        textStorage.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.minimumLineHeight *= ratio
            style.maximumLineHeight *= ratio
            style.paragraphSpacing *= ratio
            style.paragraphSpacingBefore *= ratio
            textStorage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        textStorage.endEditing()
    }

    /// Живые редакторы страниц (без редакторов колонок и ячеек): пробы вкладок проверяют, что редактор один.
    public static var livePageEditorCount: Int {
        liveEditors.allObjects.filter(\.showsPageHeader).count
    }

    /// Все живые редакторы: страниц, колонок и ячеек.
    public static var liveEditorCount: Int { liveEditors.allObjects.count }
}
