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

    /// Меню строки страницы в разделе «Избранное» от «⋯» строки: открыто на экране, пока `whileOpen` не отработает
    /// (снимок), и после него закрывается; `false` — строки в разделе нет.
    @discardableResult
    public static func showFavoriteRowMenu(ofPage pageId: UUID, in window: NSWindow, whileOpen: @escaping @MainActor () -> Void) async -> Bool {
        guard let outline = window.contentView.flatMap({ findOutline(identifier: "favorites-tree", in: $0) }),
              let source = outline.dataSource as? PageOutlineDataSource,
              let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? PageOutlineItem)?.pageId == pageId }),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? PageTreeCellView else { return false }
        (outline.rowView(atRow: row, makeIfNecessary: false) as? PageTreeRowView)?.isHovered = true
        cell.isRowHovered = true
        cell.layoutSubtreeIfNeeded()
        source.rowMenu.show(source.pageMenu(for: pageId), from: cell.menuButton)
        try? await Task.sleep(for: .milliseconds(400))
        whileOpen()
        source.rowMenu.close()
        cell.isRowHovered = false
        (outline.rowView(atRow: row, makeIfNecessary: false) as? PageTreeRowView)?.isHovered = false
        return true
    }

    private static func findOutline(identifier: String, in view: NSView) -> PageOutlineView? {
        if let outline = view as? PageOutlineView, outline.accessibilityIdentifier() == identifier { return outline }
        return view.subviews.lazy.compactMap { findOutline(identifier: identifier, in: $0) }.first
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
        // Дерево «Страницы», а не разделы «Избранное» и «Недавние» над ним.
        if let outline = view as? PageOutlineView, outline.accessibilityIdentifier() == "page-tree" { return outline }
        return view.subviews.lazy.compactMap(findOutline).first
    }
}
