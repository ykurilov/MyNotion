import AppKit
import PageEditor
import UIGallery
import VisualStyle

/// Цель снимка — блок под мышью, курсор, выделение, строка дерева, меню (ui-review 2026-10-15-round2, №25).
/// Перед действием галерея прокручивает к цели, после — проверяет, что цель целиком в окне; иначе состояние не снято.
@MainActor
enum GalleryTarget {
    // MARK: Страница

    /// Прокрутить страницу так, чтобы первая строка блока была посередине; `false` — блока нет на странице.
    static func scrollToBlock(_ blockId: UUID, in window: NSWindow) -> Bool {
        guard let textView = PageEditorPreview.textView(in: window), let start = blockStart(blockId, in: textView) else { return false }
        center(NSRange(location: start, length: 0), in: textView)
        return true
    }

    /// Прокрутить страницу так, чтобы курсор или начало выделения было посередине.
    static func scrollToSelection(in window: NSWindow) {
        guard let textView = PageEditorPreview.textView(in: window) else { return }
        center(textView.selectedRange(), in: textView)
    }

    /// Ручки «+ ⋮⋮» видны целиком.
    static func handlesProblem(_ name: String, in window: NSWindow) -> String? {
        guard let textView = PageEditorPreview.textView(in: window) else { return "нет страницы" }
        let handles = textView.subviews.first { !$0.isHidden && String(describing: type(of: $0)).contains("BlockHandlesOverlay") }
        return problem(name, at: handles.map { $0.convert($0.bounds, to: nil) }, in: textView)
    }

    /// Курсор или первая строка выделения видны целиком.
    static func selectionProblem(_ name: String, in window: NSWindow) -> String? {
        guard let textView = PageEditorPreview.textView(in: window) else { return "нет страницы" }
        return problem(name, at: rectInWindow(textView.selectedRange(), of: textView), in: textView)
    }

    // MARK: Всплывающие окна и дерево

    /// Карточки меню, окна корзины и прочих всплывающих окон не выходят за окно: снимок берёт только его.
    /// Окно карточки больше неё на прозрачный запас под тень — он за край выходить может.
    static func popupsProblem(_ name: String, in window: NSWindow) -> String? {
        let popups = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.level >= window.level && $0.frame.intersects(window.frame) }
        guard !popups.isEmpty else { return "цель не найдена: \(name)" }
        let shadow = Metrics.TrashPanel.shadowMargin
        return popups.lazy.compactMap { GalleryViewport.problem(name, at: $0.frame.insetBy(dx: shadow, dy: shadow), visible: window.frame) }.first
    }

    /// Прокрутить дерево к строке.
    static func scrollToRow(_ row: Int, in window: NSWindow) {
        outline(in: window)?.scrollRowToVisible(row)
    }

    /// Строка дерева видна целиком.
    static func rowProblem(_ name: String, _ row: Int, in window: NSWindow) -> String? {
        guard let outline = outline(in: window), let clip = outline.enclosingScrollView?.contentView else { return "нет дерева страниц" }
        return GalleryViewport.problem(name, at: outline.convert(outline.rect(ofRow: row), to: nil), visible: clip.convert(clip.bounds, to: nil))
    }

    // MARK: Геометрия

    /// Начало блока в тексте: выделить начало блока тем же путём, что галерея ставит курсор, и вернуть прежнее выделение.
    private static func blockStart(_ blockId: UUID, in textView: PageTextView) -> Int? {
        guard let window = textView.window else { return nil }
        let saved = textView.selectedRange()
        guard PageEditorPreview.select(NSRange(location: 0, length: 0), inBlock: blockId, in: window) else { return nil }
        let start = textView.selectedRange().location
        textView.setSelectedRange(saved)
        window.makeFirstResponder(nil)
        return start
    }

    private static func center(_ range: NSRange, in textView: PageTextView) {
        guard let scrollView = textView.enclosingScrollView, let target = rectInWindow(range, of: textView) else { return }
        let clip = scrollView.contentView
        let offset = GalleryViewport.scrollOffset(centering: textView.convert(target, from: nil), visibleHeight: clip.bounds.height,
                                                  documentHeight: textView.frame.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: offset))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Строка текста, где начинается диапазон, в координатах окна. Из раскладки текста, а не `firstRect`:
    /// тот без курсора в тексте отдаёт пустую рамку, а при наведении курсора нет.
    private static func rectInWindow(_ range: NSRange, of textView: PageTextView) -> CGRect? {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return nil }
        layout.ensureLayout(for: layout.documentRange)
        guard let location = content.location(content.documentRange.location, offsetBy: range.location),
              let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let offset = content.offset(from: fragment.rangeInElement.location, to: location)
        let lines = fragment.textLineFragments
        let line = lines.last { $0.characterRange.location <= offset } ?? lines.first
        let frame = fragment.layoutFragmentFrame
        let lineRect = line.map { $0.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY) } ?? frame
        guard lineRect.height > 0 else { return nil }
        let origin = textView.textContainerOrigin
        return textView.convert(lineRect.offsetBy(dx: origin.x, dy: origin.y), to: nil)
    }

    /// Видимая часть страницы: под верхней полосой и без полосы, где текст плавно уходит под неё.
    private static func problem(_ name: String, at target: CGRect?, in textView: PageTextView) -> String? {
        guard let clip = textView.enclosingScrollView?.contentView, let content = textView.window?.contentView else { return "нет страницы" }
        var visible = clip.convert(clip.bounds, to: nil).intersection(content.convert(content.bounds, to: nil))
        visible.size.height -= Metrics.Page.scrollEdgeFadeHeight
        return GalleryViewport.problem(name, at: target, visible: visible)
    }

    private static func outline(in window: NSWindow) -> NSOutlineView? {
        window.contentView.flatMap(findOutline)
    }

    private static func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.lazy.compactMap(findOutline).first
    }
}
