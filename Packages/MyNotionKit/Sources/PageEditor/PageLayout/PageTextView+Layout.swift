import AppKit
import NotesCore

/// Место обложки над шапкой: вид во всю ширину области страницы и его высота (contracts/pages-ui.md, «Шапка»).
@MainActor
final class CoverSlot {
    var view: NSView?
    var height: CGFloat = 0
    /// Обложка и вид, которые редактор уже показывает (`showAppearance`); `nil` — ещё не показывал.
    var shownAppearance: PageAppearance?
}

/// Поля страницы, от которых зависит вид шапки и колонки.
struct PageAppearance: Equatable {
    var cover: PageCover?
    var isFullWidth: Bool
    var isSmallText: Bool

    init(_ page: Page) {
        cover = page.cover
        isFullWidth = page.isFullWidth
        isSmallText = page.isSmallText
    }
}

extension PageTextView {
    /// Поставить вид обложки над шапкой (`nil` — убрать); текст и шапка сдвигаются вниз на `height`, иконка заходит
    /// на обложку.
    public func setCover(_ view: NSView?, height: CGFloat) {
        let previousTextTop = textContainerOrigin.y
        if coverSlot.view !== view {
            coverSlot.view?.removeFromSuperview()
            if let view { addSubview(view, positioned: .below, relativeTo: header) }
            coverSlot.view = view
        }
        coverSlot.height = view == nil ? 0 : height
        header.hasCover = view != nil
        layoutColumn()
        // invalidateTextContainerOrigin обновляет геометрию, но TextKit 2 сохраняет виды
        // нарисованных фрагментов. После сдвига обложкой им нужен новый проход раскладки.
        if textContainerOrigin.y != previousTextTop {
            needsLayout = true
            needsDisplay = true
        }
    }

    /// Вид в месте «под названием» шапки (US5: строка обратных ссылок; 004: свойства строки, `order` −1 — над ними);
    /// `nil` — вида с этим `order` нет, пустое место высоты не занимает.
    public func setUnderTitle(_ view: NSView?, height: CGFloat, order: Int = 0) {
        header.setUnderTitle(view, height: height, order: order)
        layoutColumn()
    }

    /// Обложку и вид страницы из документа: перекладка без пересоздания редактора; добавки шапки (обложка)
    /// получают страницу.
    public func showAppearance(of page: Page) {
        let appearance = PageAppearance(page)
        guard appearance != coverSlot.shownAppearance else { return }
        coverSlot.shownAppearance = appearance
        applyLayout(PageLayoutSettings(isFullWidth: page.isFullWidth, isSmallText: page.isSmallText, textZoom: layoutSettings.textZoom))
        for addon in headerAddons { addon.pageDidChange(page, in: self) }
    }

    /// Сменить вид страницы без пересоздания редактора: ширина колонки — сразу, размеры текста — на месте, в тех же
    /// атрибутах; колонки, ячейки и код — той же шкалой (виды 002 не пересоздаются).
    public func applyLayout(_ settings: PageLayoutSettings) {
        guard settings != layoutSettings else { return }
        let ratio = settings.fontScale / layoutSettings.fontScale
        // Место — по свежей раскладке видимой области: после правок и смены выделения она бывает устаревшей.
        if ratio != 1 { textLayoutManager?.textViewportLayoutController.layoutViewport() }
        let place = ratio != 1 ? scrollPlace() : nil
        layoutSettings = settings
        header.titleScale = settings.textZoom
        if ratio != 1 {
            mapper.fontScale = settings.fontScale
            if let textStorage { PageFontScaling.rescale(textStorage, in: NSRange(location: 0, length: textStorage.length), to: settings.fontScale) }
            typingAttributes = typingAttributes
            for codeBlock in codeBlocks.allViews { codeBlock.applyFontScale(settings.fontScale) }
            for editor in embeddedFlowEditors { editor.applyLayout(PageLayoutSettings(isSmallText: settings.isSmallText, textZoom: settings.textZoom)) }
        }
        layoutColumn()
        needsLayout = true
        needsDisplay = true
        // Новая шкала — тот же блок у верха видимой области, сдвиг в нём — в той же шкале.
        if let place { scroll(to: TabScroll(blockId: place.blockId, offset: place.offset * ratio)) }
    }

    /// Масштаб текста приложения сменился (⌘+, ⌘−, ⌘0): колонки и ячейки получают его от своей страницы.
    @objc func pageTextZoomDidChange(_ notification: Notification) {
        guard showsPageHeader, let zoom = notification.object as? PageTextZoom, zoom === textZoom else { return }
        var settings = layoutSettings
        settings.textZoom = zoom.scale
        applyLayout(settings)
    }

    /// Живые редакторы страниц (без редакторов колонок и ячеек): пробы вкладок проверяют, что редактор один.
    public static var livePageEditorCount: Int {
        liveEditors.allObjects.filter(\.showsPageHeader).count
    }

    /// Все живые редакторы: страниц, колонок и ячеек.
    public static var liveEditorCount: Int { liveEditors.allObjects.count }
}
