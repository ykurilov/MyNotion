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

    /// Меню строки страницы в разделе «Избранное»: открыто на экране, пока `whileOpen` не отработает (снимок),
    /// и после него закрывается. Меню системное — показывается, пока не закрыто; `false` — строки в разделе нет.
    @discardableResult
    public static func showFavoriteRowMenu(ofPage pageId: UUID, in window: NSWindow, whileOpen: @escaping @MainActor () -> Void) -> Bool {
        guard let outline = window.contentView.flatMap({ findOutline(identifier: "favorites-tree", in: $0) }),
              let source = outline.dataSource as? PageOutlineDataSource,
              let row = (0..<outline.numberOfRows).first(where: { (outline.item(atRow: $0) as? PageOutlineItem)?.pageId == pageId }),
              let rowView = outline.rowView(atRow: row, makeIfNecessary: false) else { return false }
        let menu = source.pageMenu(for: pageId)
        // Пока меню открыто, цикл событий в режиме отслеживания: очередь GCD стоит, нужен таймер во всех режимах.
        let timer = Timer(timeInterval: 0.6, target: MenuCloser(menu: menu, whileOpen: whileOpen),
                          selector: #selector(MenuCloser.fire), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 120, y: rowView.bounds.maxY + 4), in: rowView)
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

/// Цель таймера: снять снимок и закрыть открытое меню.
@MainActor
private final class MenuCloser: NSObject {
    private let menu: NSMenu
    private let whileOpen: @MainActor () -> Void

    init(menu: NSMenu, whileOpen: @escaping @MainActor () -> Void) {
        self.menu = menu
        self.whileOpen = whileOpen
    }

    @objc func fire() {
        whileOpen()
        menu.cancelTracking()
    }
}
