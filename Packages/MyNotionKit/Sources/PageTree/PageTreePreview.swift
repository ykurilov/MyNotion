import AppKit

/// Состояния дерева без мыши и клавиатуры: для галереи интерфейса (флаг `--ui-gallery`).
@MainActor
public enum PageTreePreview {
    /// Номер строки страницы в дереве; `nil` — строки не видно (ветка свёрнута).
    public static func row(ofPage pageId: UUID, in window: NSWindow) -> Int? {
        guard let outline = outline(in: window) else { return nil }
        return (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? PageOutlineItem)?.pageId == pageId }
    }

    /// Свернуть или развернуть ветку, как стрелкой строки: свёрнутость запоминается окном.
    @discardableResult
    public static func setExpanded(_ expanded: Bool, page pageId: UUID, in window: NSWindow) -> Bool {
        guard let outline = outline(in: window), let row = row(ofPage: pageId, in: window), let item = outline.item(atRow: row) else {
            return false
        }
        if expanded { outline.expandItem(item) } else { outline.collapseItem(item) }
        return true
    }

    /// Строка страницы — в режиме переименования, как по Enter.
    @discardableResult
    public static func beginRenaming(page pageId: UUID, in window: NSWindow) -> Bool {
        guard let outline = outline(in: window), let row = row(ofPage: pageId, in: window),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? PageTreeCellView else { return false }
        cell.beginRenaming()
        return true
    }

    /// Снять подсветку «под мышью» со всех строк.
    public static func clearHover(in window: NSWindow) {
        guard let outline = outline(in: window) else { return }
        for row in 0..<outline.numberOfRows {
            (outline.rowView(atRow: row, makeIfNecessary: false) as? PageTreeRowView)?.isHovered = false
        }
    }

    private static func outline(in window: NSWindow) -> PageOutlineView? {
        window.contentView.flatMap(findOutline)
    }

    private static func findOutline(in view: NSView) -> PageOutlineView? {
        if let outline = view as? PageOutlineView { return outline }
        return view.subviews.lazy.compactMap(findOutline).first
    }
}
