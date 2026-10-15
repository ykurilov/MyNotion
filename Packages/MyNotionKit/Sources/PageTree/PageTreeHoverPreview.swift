import AppKit

/// Строка дерева «под мышью» без мыши: для снимков окна (флаг `--hover-sidebar-row`).
@MainActor
public enum PageTreeHoverPreview {
    /// Подсветить строку `row` первого дерева страниц в окне; `false` — такой строки нет.
    @discardableResult
    public static func hoverRow(_ row: Int, in window: NSWindow) -> Bool {
        guard let outline = window.contentView.flatMap(findOutline), row < outline.numberOfRows,
              let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? PageTreeRowView else { return false }
        rowView.isHovered = true
        rowView.layoutSubtreeIfNeeded()
        return true
    }

    private static func findOutline(in view: NSView) -> PageOutlineView? {
        if let outline = view as? PageOutlineView { return outline }
        return view.subviews.lazy.compactMap(findOutline).first
    }
}
