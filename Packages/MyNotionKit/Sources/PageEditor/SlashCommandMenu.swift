import AppKit
import CoreText
import NotesCore
import VisualStyle

/// Строка всплывающего меню блоков: тип блока или «Удалить».
struct PopupMenuItem: Equatable {
    enum Action: Equatable {
        case setKind(BlockKind)
        /// Окно цветов для блока.
        case color
        case delete
        /// Только в меню «/»: колонки из N пустых колонок, таблица 2 × 3 (US6).
        case insertColumns(Int)
        case insertTable
        /// Только в меню «/»: новая база — встроенная или на всю страницу (004); создаёт владелец окна.
        case insertDatabase(inline: Bool)
        /// Меню блока: подменю типов, как «Turn into» у Notion.
        case turnInto
        /// Меню блока: копия блока со всем вложенным сразу под ним (⌘D).
        case duplicate
        /// Меню блока: окно «Переместить в…» для блока или выделенных блоков (⇧⌘P, US4).
        case moveTo
    }

    /// Значок строки: короткая надпись, системный значок, квадрат чекбокса или лист страницы (как в дереве).
    enum Icon: Equatable {
        case label(String)
        case symbol(String)
        case checkbox
        case document
    }

    var title: String
    var icon: Icon
    var keywords: [String]
    var action: Action
    /// Серая подсказка клавиш справа в меню блока и в «Преобразовать в»: «⌘D», «Del», «⌥⌘1».
    var hint: String? = nil
    /// Над строкой — черта между группами меню блока.
    var startsGroup = false

    var identifier: String {
        switch action {
        case .setKind(let kind): kind.rawValue
        case .color: "color"
        case .delete: "delete"
        case .insertColumns(let count): "columns-\(count)"
        case .insertTable: "table"
        case .insertDatabase(let inline): inline ? "database-inline" : "database-full-page"
        case .turnInto: "turn-into"
        case .duplicate: "duplicate"
        case .moveTo: "move-to"
        }
    }

    /// Строка открывает подменю справа: «Преобразовать в», «Цвет».
    var opensSubmenu: Bool { action == .turnInto || action == .color }

    /// Быстрые символы типа, как справа в меню «/» у Notion: набранные в начале строки с пробелом, они меняют тип блока.
    var shortcut: String? {
        guard case .setKind(let kind) = action else { return nil }
        return kind.descriptor.markdownShortcuts.first
    }

    /// Типы блоков меню «/» и «Превратить в» — из описателей типов (`BlockKinds/`).
    static var blockKinds: [PopupMenuItem] { BlockKindRegistry.menuItems }

    /// Меню «/»: типы блоков и то, что только вставляется (колонки, таблица).
    static var slashItems: [PopupMenuItem] { blockKinds + BlockKindRegistry.insertMenuItems }

    static let turnInto = PopupMenuItem(title: "Преобразовать в", icon: .symbol("arrow.triangle.2.circlepath"), keywords: [],
                                        action: .turnInto)
    static let color = PopupMenuItem(title: "Цвет", icon: .symbol("paintbrush"), keywords: [], action: .color)
    static let duplicate = PopupMenuItem(title: "Дублировать", icon: .symbol("plus.square.on.square"), keywords: [], action: .duplicate,
                                         hint: "⌘D", startsGroup: true)
    static let moveTo = PopupMenuItem(title: "Переместить в", icon: .symbol("arrow.turn.up.right"), keywords: [], action: .moveTo,
                                      hint: "⌘⇧P")
    static let delete = PopupMenuItem(title: "Удалить", icon: .symbol("trash"), keywords: [], action: .delete, hint: "Del")

    /// Заголовок меню блока — название его типа, как «Text» у Notion.
    static func blockMenuTitle(of kind: BlockKind) -> String {
        if let item = blockKinds.first(where: { $0.action == .setKind(kind) }) { return item.title }
        switch kind {
        case .table: return "Таблица"
        case .columnList: return "Колонки"
        case .pageLink: return "Страница"
        default: return kind.rawValue
        }
    }

    /// Меню блока «⋮⋮», как у Notion 7.39: короткое, типы — в подменю. Подстраницу не дублировать: у страницы одна ссылка.
    static func blockMenuItems(for kind: BlockKind) -> [PopupMenuItem] {
        var items: [PopupMenuItem] = [.turnInto, .color]
        var moveTo = PopupMenuItem.moveTo
        if kind != .pageLink { items.append(.duplicate) } else { moveTo.startsGroup = true }
        return items + [moveTo, .delete]
    }

    /// Меню «/»: поиск по названию и словам-подсказкам без учёта регистра.
    static func slashItems(matching query: String) -> [PopupMenuItem] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return slashItems }
        return slashItems.filter { item in
            item.title.lowercased().contains(query) || item.keywords.contains { $0.hasPrefix(query) }
        }
    }
}

/// Вид меню: «/» — с заголовком раздела, быстрыми символами и строкой «Закрыть меню»; меню блока — заголовок с типом
/// блока, группы через черту, подсказки клавиш и стрелки подменю; список типов (подменю «Преобразовать в» и список
/// панели форматирования) — строки с галочкой у текущего; `list` — просто строки (меню вставленной ссылки).
enum PopupMenuStyle {
    case slash
    case blockMenu
    case kindPicker
    case list

    var width: CGFloat {
        switch self {
        case .slash: Metrics.PopupMenu.slashMenuWidth
        case .blockMenu: Metrics.PopupMenu.blockMenuWidth
        case .kindPicker: Metrics.PopupMenu.kindListWidth
        case .list: Metrics.PopupMenu.listMenuWidth
        }
    }
    var sectionTitle: String? { self == .slash ? "Основные блоки" : nil }
    var hasCloseRow: Bool { self == .slash }
    /// Шаг строк: в меню «/» — 33, в остальных — 29, как у Notion.
    var rowHeight: CGFloat { self == .slash ? Metrics.PopupMenu.rowHeight : Metrics.PopupMenu.compactRowHeight }
    /// Сколько строк видно без прокрутки; у остальных меню — сколько помещается на экране.
    var maximumVisibleRows: Int { self == .slash ? Metrics.PopupMenu.maximumVisibleRows : .max }

    var windowIdentifier: String {
        switch self {
        case .slash: "slash-menu"
        case .blockMenu: "block-menu"
        case .kindPicker: "kind-menu"
        case .list: "link-menu"
        }
    }
}

/// Всплывающее меню блоков (contracts/visual-style.md, «Всплывающие меню»): окно без рамки над страницей.
/// Ввод остаётся в тексте: стрелки, Enter и Esc приходят от `PageTextView`.
@MainActor
final class PopupMenuWindow: NSPanel {
    /// Место под тени вокруг меню.
    static let shadowMargin: CGFloat = 32
    let menuView: PopupMenuView

    init(style: PopupMenuStyle) {
        menuView = PopupMenuView(style: style)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = menuView
        setAccessibilityIdentifier(style.windowIdentifier)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Показать под строкой `anchor` (координаты экрана), а если внизу места нет — над ней. Не помещается ни там,
    /// ни там — встаёт, где места больше, и список прокручивается.
    /// Невидимое окно страницы (модульные проверки) — только место, на экран меню не выходит.
    func show(below anchor: NSRect, parent: NSWindow) {
        let margin = Self.shadowMargin
        let spacing = Metrics.PopupMenu.anchorSpacing
        var placeAbove = false
        if let screen = parent.screen?.visibleFrame {
            let below = anchor.minY - spacing - screen.minY, above = screen.maxY - anchor.maxY - spacing
            menuView.maximumHeight = .greatestFiniteMagnitude
            let wanted = menuView.fittingMenuSize.height
            placeAbove = wanted > below && above > below
            menuView.maximumHeight = placeAbove ? above : below
        }
        let size = menuView.fittingMenuSize
        let y = placeAbove ? anchor.maxY + spacing : anchor.minY - spacing - size.height
        setFrame(NSRect(x: anchor.minX - margin, y: y - margin, width: size.width + 2 * margin, height: size.height + 2 * margin), display: true)
        PopupWindows.show(self, over: parent)
    }

    /// Подменю справа от меню `menu` (без тени, координаты экрана): первая строка — вровень со строкой `row`,
    /// заходит на меню на 4, как у Notion; не помещается на экране — сдвигается вверх и прокручивается.
    func show(besideRow row: NSRect, of menu: NSRect, parent: NSWindow) {
        let margin = Self.shadowMargin
        let screen = parent.screen?.visibleFrame ?? NSRect(x: menu.minX, y: -10_000, width: 100_000, height: 20_000)
        menuView.maximumHeight = screen.height
        let size = menuView.fittingMenuSize
        var top = row.maxY + Metrics.PopupMenu.verticalPadding
        top = min(screen.maxY, max(top, screen.minY + size.height))
        var x = menu.maxX - Metrics.PopupMenu.submenuOverlap
        if x + size.width > screen.maxX { x = menu.minX - size.width + Metrics.PopupMenu.submenuOverlap }
        setFrame(NSRect(x: x - margin, y: top - size.height - margin, width: size.width + 2 * margin, height: size.height + 2 * margin),
                 display: true)
        PopupWindows.show(self, over: parent)
    }

    /// Показать меню на месте `frame` (без тени, координаты экрана).
    func show(menuFrame frame: NSRect, parent: NSWindow) {
        setFrame(frame.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), display: true)
        PopupWindows.show(self, over: parent)
    }

    /// Место меню без тени, в координатах экрана.
    var menuFrame: NSRect { frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin) }

    /// Место строки `item` на экране.
    func rowFrameOnScreen(_ item: PopupMenuItem) -> NSRect? {
        guard let local = menuView.rowFrame(of: item) else { return nil }
        return convertToScreen(menuView.convert(local, to: nil))
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

@MainActor
final class PopupMenuView: NSView {
    let style: PopupMenuStyle
    private(set) var items: [PopupMenuItem] = []
    private(set) var selectedIndex = 0
    private var rows: [PopupMenuRowView] = []
    /// Строки лежат здесь: длинный список прокручивается внутри, края строк срезаются.
    private let rowsClip = PopupMenuRowsClipView()
    /// Строка «Закрыть меню» внизу меню «/»: мышью закрывает меню, стрелками не выбирается — как у Notion.
    private(set) var footer: PopupMenuFooterView?
    var onChoose: ((PopupMenuItem) -> Void)?
    /// Мышь навела строку (меню блока открывает по ней подменю).
    var onHover: ((PopupMenuItem) -> Void)?
    /// Отмеченная галочкой строка (текущий тип в списке типов).
    var checkedItem: PopupMenuItem? {
        didSet { for row in rows { row.isChecked = row.item == checkedItem } }
    }
    var onClose: (() -> Void)? {
        get { footer?.onClick }
        set { footer?.onClick = newValue }
    }
    /// Заголовок над строками: «Основные блоки» в меню «/», тип блока в меню блока.
    var sectionTitle: String? {
        didSet { if sectionTitle != oldValue { needsLayout = true; needsDisplay = true } }
    }
    /// Сколько места по высоте у карточки на экране; длиннее — список прокручивается.
    var maximumHeight: CGFloat = .greatestFiniteMagnitude {
        didSet { if maximumHeight != oldValue { scrollOffset = clampedOffset(scrollOffset); needsLayout = true } }
    }
    /// Насколько прокручен список строк, в точках.
    private(set) var scrollOffset: CGFloat = 0

    init(style: PopupMenuStyle) {
        self.style = style
        sectionTitle = style.sectionTitle
        super.init(frame: .zero)
        setAccessibilityRole(.menu)
        addSubview(rowsClip)
        if style.hasCloseRow {
            let footer = PopupMenuFooterView()
            addSubview(footer)
            self.footer = footer
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    /// От верха меню до первой строки и от последней строки до низа.
    private var rowsTop: CGFloat {
        Metrics.PopupMenu.verticalPadding + (sectionTitle == nil ? 0 : Metrics.PopupMenu.sectionHeaderHeight)
    }

    private var rowsBottom: CGFloat {
        footer == nil ? Metrics.PopupMenu.verticalPadding : Metrics.PopupMenu.rowHeight + Metrics.PopupMenu.bottomPadding
    }

    /// Верх каждой строки от верха списка: черта группы добавляет место над строкой.
    private var rowTops: [CGFloat] {
        var tops: [CGFloat] = []
        var y: CGFloat = 0
        for (index, item) in items.enumerated() {
            if item.startsGroup, index > 0 { y += Metrics.PopupMenu.groupSeparatorHeight }
            tops.append(y)
            y += style.rowHeight
        }
        return tops
    }

    private var contentHeight: CGFloat { (rowTops.last ?? -style.rowHeight) + style.rowHeight }

    /// Высота видимой части списка: не больше строк стиля и не больше места на экране.
    private var visibleRowsHeight: CGFloat {
        let byRows = style.maximumVisibleRows == .max ? contentHeight
            : min(contentHeight, CGFloat(style.maximumVisibleRows) * style.rowHeight)
        let byScreen = max(style.rowHeight, maximumHeight - rowsTop - rowsBottom)
        // Целое число строк: нижняя строка не срезана посередине.
        let fitted = byScreen >= byRows ? byRows : (byScreen / style.rowHeight).rounded(.down) * style.rowHeight
        return max(min(byRows, fitted), min(contentHeight, style.rowHeight))
    }

    /// Список не помещается и прокручивается.
    var isScrollable: Bool { contentHeight > visibleRowsHeight + 0.5 }

    var fittingMenuSize: NSSize {
        NSSize(width: style.width, height: rowsTop + visibleRowsHeight + rowsBottom)
    }

    private var menuRect: NSRect {
        let margin = PopupMenuWindow.shadowMargin
        return NSRect(x: margin, y: margin, width: style.width, height: fittingMenuSize.height)
    }

    func setItems(_ items: [PopupMenuItem]) {
        guard items != self.items else { return }
        self.items = items
        selectedIndex = 0
        scrollOffset = 0
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, item in
            let row = PopupMenuRowView(item: item, style: style)
            row.isChecked = item == checkedItem
            row.onHover = { [weak self] in
                self?.select(index, reveal: false)
                self?.onHover?(item)
            }
            row.onClick = { [weak self] in self?.onChoose?(item) }
            rowsClip.addSubview(row)
            return row
        }
        needsLayout = true
        layoutRows()
        updateSelection()
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        select((selectedIndex + delta + items.count) % items.count, reveal: true)
    }

    var selectedItem: PopupMenuItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    /// Виды строк по порядку (проверки вида).
    var rowViews: [PopupMenuRowView] { rows }

    /// Место строки `item` в координатах меню.
    func rowFrame(of item: PopupMenuItem) -> NSRect? {
        guard let index = items.firstIndex(of: item), rows.indices.contains(index) else { return nil }
        layoutSubtreeIfNeeded()
        return rows[index].convert(rows[index].bounds, to: self)
    }

    /// Выбрать строку `item` (галочку при открытии списка) и прокрутить к ней.
    func select(_ item: PopupMenuItem) {
        guard let index = items.firstIndex(of: item) else { return }
        select(index, reveal: true)
    }

    private func select(_ index: Int, reveal: Bool) {
        selectedIndex = index
        if reveal { revealSelection() }
        updateSelection()
    }

    /// Выбранная строка видна, даже если строк больше, чем помещается.
    private func revealSelection() {
        let tops = rowTops
        guard tops.indices.contains(selectedIndex) else { return }
        let top = tops[selectedIndex], visible = visibleRowsHeight
        if top < scrollOffset { scrollOffset = top }
        if top + style.rowHeight > scrollOffset + visible { scrollOffset = top + style.rowHeight - visible }
        scrollOffset = clampedOffset(scrollOffset)
        layoutRows()
    }

    private func clampedOffset(_ offset: CGFloat) -> CGFloat {
        max(0, min(offset, contentHeight - visibleRowsHeight))
    }

    override func scrollWheel(with event: NSEvent) {
        guard isScrollable else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * style.rowHeight
        scrollOffset = clampedOffset(scrollOffset - delta)
        layoutRows()
        needsDisplay = true
    }

    private func updateSelection() {
        for (index, row) in rows.enumerated() { row.isSelected = index == selectedIndex }
    }

    private func layoutRows() {
        let menu = menuRect
        let inset = Metrics.PopupMenu.rowInset
        rowsClip.frame = NSRect(x: menu.minX + inset, y: menu.minY + rowsTop, width: menu.width - 2 * inset, height: visibleRowsHeight)
        rowsClip.separatorTops = []
        for (index, (row, top)) in zip(rows, rowTops).enumerated() {
            row.frame = NSRect(x: 0, y: top - scrollOffset, width: rowsClip.bounds.width, height: style.rowHeight)
            // Строка целиком за краем списка не ловит мышь и не видна вспомогательным технологиям.
            row.isHidden = row.frame.maxY <= 0 || row.frame.minY >= rowsClip.bounds.height
            if items[index].startsGroup, index > 0 {
                rowsClip.separatorTops.append(top - scrollOffset - Metrics.PopupMenu.groupSeparatorHeight / 2)
            }
        }
        rowsClip.needsDisplay = true
        footer?.frame = NSRect(x: menu.minX + inset, y: menu.maxY - rowsBottom, width: menu.width - 2 * inset, height: Metrics.PopupMenu.rowHeight)
    }

    override func layout() {
        super.layout()
        scrollOffset = clampedOffset(scrollOffset)
        layoutRows()
        updateSelection()
    }

    override func draw(_ dirtyRect: NSRect) {
        let menu = menuRect
        PopupSurface.draw(card: menu)
        if isScrollable { drawScrollIndicator(in: menu) }
        guard let sectionTitle else { return }
        let style = Typography.popupMenuSectionHeader
        let x = menu.minX + Metrics.PopupMenu.rowInset + Metrics.PopupMenu.rowHorizontalPadding
        let top = menu.minY + Metrics.PopupMenu.verticalPadding + (Metrics.PopupMenu.sectionHeaderHeight - style.lineHeight) / 2
        NSAttributedString(string: sectionTitle, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary])
            .draw(in: NSRect(x: x, y: top, width: menu.maxX - x, height: style.lineHeight))
    }

    /// Полоса прокрутки, как у Notion: серая, скруглённая, у правого края списка.
    private func drawScrollIndicator(in menu: NSRect) {
        let track = NSRect(x: menu.maxX - Metrics.PopupMenu.scrollIndicatorInset - Metrics.PopupMenu.scrollIndicatorWidth,
                           y: menu.minY + rowsTop, width: Metrics.PopupMenu.scrollIndicatorWidth, height: visibleRowsHeight)
        let ratio = visibleRowsHeight / contentHeight
        let height = max(track.height * ratio, 24)
        let progress = scrollOffset / max(1, contentHeight - visibleRowsHeight)
        let thumb = NSRect(x: track.minX, y: track.minY + (track.height - height) * progress, width: track.width, height: height)
        Palette.textSecondary.withAlphaComponent(0.35).setFill()
        let radius = Metrics.PopupMenu.scrollIndicatorWidth / 2
        NSBezierPath(roundedRect: thumb, xRadius: radius, yRadius: radius).fill()
    }
}

/// Видимая часть списка строк: срезает строки за краем и рисует черты между группами.
@MainActor
final class PopupMenuRowsClipView: NSView {
    /// Середины промежутков между группами, в координатах вида.
    var separatorTops: [CGFloat] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.border.setFill()
        let padding = Metrics.PopupMenu.rowHorizontalPadding
        for y in separatorTops {
            NSRect(x: padding, y: (y - 0.5).rounded(.down), width: bounds.width - 2 * padding, height: 1).fill()
        }
    }
}

/// Строка «Закрыть меню» с «esc» справа серым, как «Close menu» у Notion.
@MainActor
final class PopupMenuFooterView: NSView {
    let title = "Закрыть меню"
    let key = "esc"
    var onClick: (() -> Void)?
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier("popup-close")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered { PopupMenuRowView.drawHighlight(in: bounds) }
        let padding = Metrics.PopupMenu.rowHorizontalPadding
        PopupMenuRowView.drawShortcut(key, in: bounds)
        let style = Typography.popupMenuTitle
        NSAttributedString(string: title, attributes: [.font: style.font, .foregroundColor: Palette.textPrimary])
            .draw(in: NSRect(x: padding, y: (bounds.height - style.lineHeight) / 2, width: bounds.width - 2 * padding, height: style.lineHeight))
    }
}

/// Строка меню: значок, название и в меню «/» быстрые символы справа; выбранная — на фоне hoverBackground.
@MainActor
final class PopupMenuRowView: NSView {
    let item: PopupMenuItem
    let style: PopupMenuStyle
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var isChecked = false { didSet { if isChecked != oldValue { needsDisplay = true } } }
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?

    init(item: PopupMenuItem, style: PopupMenuStyle) {
        self.item = item
        self.style = style
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        setAccessibilityIdentifier("popup-item-\(item.identifier)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// Подсветка выбранной строки: на 1 меньше строки сверху и снизу, скругление 6.
    static func drawHighlight(in bounds: NSRect) {
        Palette.hoverBackground.setFill()
        let radius = Metrics.PopupMenu.rowCornerRadius
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: Metrics.PopupMenu.rowHighlightInset), xRadius: radius, yRadius: radius).fill()
    }

    /// Серая подсказка справа в строке («#», «esc»); возвращает её левый край.
    @discardableResult
    static func drawShortcut(_ text: String, in bounds: NSRect) -> CGFloat {
        let style = Typography.popupMenuShortcut
        let string = NSAttributedString(string: text, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary])
        let width = ceil(string.size().width)
        let x = bounds.maxX - Metrics.PopupMenu.rowHorizontalPadding - width
        string.draw(in: NSRect(x: x, y: (bounds.height - style.lineHeight) / 2, width: width, height: style.lineHeight))
        return x
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected { Self.drawHighlight(in: bounds) }
        let padding = Metrics.PopupMenu.rowHorizontalPadding
        let iconSize = Metrics.PopupMenu.iconSize
        drawIcon(in: NSRect(x: padding, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize))

        var textEnd = bounds.maxX - padding
        if style == .slash, let shortcut = item.shortcut {
            textEnd = Self.drawShortcut(shortcut, in: bounds) - padding
        }
        if style == .blockMenu {
            if item.opensSubmenu {
                textEnd = drawChevron() - padding
            } else if let hint = item.hint {
                textEnd = Self.drawShortcut(hint, in: bounds) - padding
            }
        }
        if isChecked {
            textEnd = drawCheckmark() - padding
        } else if style == .kindPicker, let hint = item.hint {
            // «Преобразовать в»: клавиши типа справа, как у Notion.
            textEnd = Self.drawShortcut(hint, in: bounds) - padding
        }
        let textX = padding + iconSize + Metrics.PopupMenu.iconToTitleSpacing
        let titleStyle = Typography.popupMenuTitle
        let title = NSAttributedString(string: item.title, attributes: [
            .font: titleStyle.font, .foregroundColor: item.action == .delete ? Palette.destructiveText : Palette.textPrimary,
        ])
        title.draw(in: NSRect(x: textX, y: (bounds.height - titleStyle.lineHeight) / 2, width: textEnd - textX, height: titleStyle.lineHeight))
    }

    /// Стрелка подменю справа в строке, серая, как у Notion; возвращает её левый край.
    private func drawChevron() -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.PopupMenu.checkmarkGlyphSize, weight: .medium)
            .applying(.init(paletteColors: [Palette.textSecondary]))
        guard let symbol = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return bounds.maxX
        }
        let size = symbol.size
        let x = bounds.maxX - Metrics.PopupMenu.rowHorizontalPadding - size.width
        symbol.draw(in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return x
    }

    /// Галочка текущего типа справа в строке; возвращает её левый край.
    private func drawCheckmark() -> CGFloat {
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.PopupMenu.checkmarkGlyphSize, weight: .medium)
            .applying(.init(paletteColors: [Palette.textPrimary]))
        guard let symbol = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return bounds.maxX
        }
        let size = symbol.size
        let x = bounds.maxX - Metrics.PopupMenu.rowHorizontalPadding - size.width
        symbol.draw(in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return x
    }

    /// Значок типа без рамки, как в Notion: рисунок вписан в квадрат `iconInkSize` по центру места значка.
    private func drawIcon(in rect: NSRect) {
        Self.drawIcon(item.icon, color: item.action == .delete ? Palette.destructiveText : Palette.textPrimary, in: rect)
    }

    /// Значок строки меню; им же рисуется тип блока в панели форматирования.
    static func drawIcon(_ icon: PopupMenuItem.Icon, color: NSColor, in rect: NSRect) {
        let side = Metrics.PopupMenu.iconInkSize
        switch icon {
        case .label(let text):
            let font = labelFont
            let line = BlockDecorationPainter.textLine(text, font: font)
            let ink = CTLineGetImageBounds(line, nil)
            // Перевёрнутые координаты: прописные стоят по середине места, нижний индекс «H₁» уходит под строку.
            BlockDecorationPainter.drawLine(line, color: color,
                                            baselineOrigin: CGPoint(x: rect.midX - ink.midX, y: rect.midY + font.capHeight / 2))
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.PopupMenu.iconGlyphSize, weight: .regular)
                .applying(.init(paletteColors: [color]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
                return
            }
            // У картинки значка пустые поля разной ширины: вписывать сам рисунок, а не картинку.
            let ink = inkRect(of: symbol)
            let scale = side / max(ink.width, ink.height, 1)
            let origin = CGPoint(x: rect.midX - ink.midX * scale, y: rect.midY - ink.midY * scale)
            symbol.draw(in: NSRect(x: origin.x, y: origin.y, width: symbol.size.width * scale, height: symbol.size.height * scale),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .checkbox:
            let square = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            let inset = Metrics.Checkbox.borderWidth / 2
            let path = NSBezierPath(roundedRect: square.insetBy(dx: inset, dy: inset), xRadius: Metrics.Checkbox.cornerRadius,
                                    yRadius: Metrics.Checkbox.cornerRadius)
            path.lineWidth = Metrics.Checkbox.borderWidth
            color.setStroke()
            path.stroke()
        case .document:
            // Лист занимает 0,79 высоты своего квадрата: по высоте он вровень с другими значками.
            let size = side / 0.79
            DocumentGlyph.image(size: size, color: color)
                .draw(in: NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2, width: size, height: size),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// Где внутри картинки сам рисунок, в её точках сверху вниз.
    static func inkRect(of image: NSImage) -> NSRect {
        let scale: CGFloat = 4
        let width = Int((image.size.width * scale).rounded(.up)), height = Int((image.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return NSRect(origin: .zero, size: image.size)
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return NSRect(origin: .zero, size: image.size) }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            for column in 0..<width where data[row * context.bytesPerRow + column * 4 + 3] > 76 {
                minX = min(minX, column); maxX = max(maxX, column); minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard maxX >= minX else { return NSRect(origin: .zero, size: image.size) }
        // Первая строка памяти — верх картинки.
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// Шрифт надписей «T», «H₁»…: один на все; если самая широкая не влезает в квадрат рисунка — мельче.
    private static let labelFont: NSFont = {
        let base = NSFont.systemFont(ofSize: Metrics.PopupMenu.iconGlyphSize, weight: .regular)
        let widest = PopupMenuItem.blockKinds.compactMap { item -> CGFloat? in
            guard case .label(let text) = item.icon else { return nil }
            return CTLineGetImageBounds(BlockDecorationPainter.textLine(text, font: base), nil).width
        }.max() ?? 0
        let side = Metrics.PopupMenu.iconInkSize
        return widest <= side ? base : NSFont.systemFont(ofSize: base.pointSize * side / widest, weight: .regular)
    }()
}

/// Какое меню открыто и для какого блока. Меню «/» живёт, пока курсор в том же абзаце за символом «/».
/// У меню блока справа открывается подменю: список типов («Преобразовать в») или окно цветов. Стрелки и Enter
/// управляют тем окном, где фокус: → и Enter на строке подменю переводят фокус в него, ← и Esc возвращают в меню.
@MainActor
final class EditorPopupController {
    enum Session {
        /// `slashLocation` — где стоит «/» в тексте.
        case slash(blockId: UUID, slashLocation: Int)
        case block(blockId: UUID)
    }

    /// Открытое подменю меню блока.
    enum Submenu: Equatable {
        case turnInto
        case color
    }

    weak var textView: PageTextView?
    private(set) var session: Session?
    private var window: PopupMenuWindow?
    /// Список типов подменю «Преобразовать в».
    private var kindWindow: PopupMenuWindow?
    private(set) var submenu: Submenu?
    /// Стрелки и Enter — у подменю, а не у меню.
    private(set) var isSubmenuFocused = false
    /// Строка, под которой стоит меню (координаты экрана).
    private var anchor: NSRect = .zero
    /// Отложенная смена подменю по наведению мыши.
    private var pendingHover: DispatchWorkItem?
    /// Приложение ушло в фон — меню закрывается.
    /// Подписка снимается в `deinit` — он не привязан к главному потоку.
    nonisolated(unsafe) private var deactivationObserver: NSObjectProtocol?

    deinit {
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }

    var isOpen: Bool { session != nil }
    var visibleItems: [PopupMenuItem] { window?.menuView.items ?? [] }
    var selectedItem: PopupMenuItem? { window?.menuView.selectedItem }
    /// Строки подменю «Преобразовать в», выбранная в нём и отмеченная галочкой.
    var submenuItems: [PopupMenuItem] { submenu == .turnInto ? kindWindow?.menuView.items ?? [] : [] }
    var submenuSelectedItem: PopupMenuItem? { submenu == .turnInto ? kindWindow?.menuView.selectedItem : nil }
    var submenuCheckedItem: PopupMenuItem? { submenu == .turnInto ? kindWindow?.menuView.checkedItem : nil }
    /// Заголовок меню блока — тип блока.
    var sectionTitle: String? { window?.menuView.sectionTitle }

    /// Рамка меню без места под тень, в координатах экрана; `nil` — меню закрыто.
    var menuFrame: NSRect? {
        guard isOpen, let window else { return nil }
        let margin = PopupMenuWindow.shadowMargin
        return window.frame.insetBy(dx: margin, dy: margin)
    }

    /// Рамка подменю типов без тени; `nil` — не открыто.
    var submenuFrame: NSRect? { submenu == .turnInto ? kindWindow?.menuFrame : nil }

    private var blockId: UUID? {
        if case .block(let id)? = session { id } else { nil }
    }

    func open(_ session: Session, items: [PopupMenuItem], below anchor: NSRect, title: String? = nil) {
        guard let textView, let parent = textView.window else { return }
        closeSubmenu()
        let style: PopupMenuStyle = if case .slash = session { .slash } else { .blockMenu }
        if window?.menuView.style != style {
            window?.hide()
            window = PopupMenuWindow(style: style)
        }
        self.session = session
        self.anchor = anchor
        guard let window else { return }
        window.menuView.onChoose = { [weak self] item in self?.choose(item) }
        window.menuView.onClose = { [weak self] in self?.close() }
        window.menuView.onHover = { [weak self] item in self?.hovered(item) }
        if style == .blockMenu { window.menuView.sectionTitle = title }
        window.menuView.setItems(items)
        window.show(below: anchor, parent: parent)
        if deactivationObserver == nil { deactivationObserver = PopupWindows.onAppDeactivation { [weak self] in self?.close() } }
        textView.popupSessionDidChange()
    }

    func update(items: [PopupMenuItem]) {
        guard let window, let parent = textView?.window, items != window.menuView.items else { return }
        window.menuView.setItems(items)
        window.show(below: anchor, parent: parent)
    }

    /// Стрелки ↑↓ — в окне с фокусом; в меню блока уход со строки подменю закрывает подменю.
    func moveSelection(by delta: Int) {
        if isSubmenuFocused, submenu == .turnInto {
            kindWindow?.menuView.moveSelection(by: delta)
            return
        }
        window?.menuView.moveSelection(by: delta)
        if submenu != nil { closeSubmenu() }
    }

    /// Enter: в подменю — выбор типа; на строке с подменю — открыть его и перейти в него; иначе — действие строки.
    func choose(_ item: PopupMenuItem? = nil) {
        if item == nil, isSubmenuFocused, submenu == .turnInto {
            if let kind = kindWindow?.menuView.selectedItem { apply(kind) }
            return
        }
        guard session != nil, let item = item ?? selectedItem else { return }
        if item.opensSubmenu, blockId != nil {
            openSubmenu(for: item, focus: true)
            return
        }
        apply(item)
    }

    private func apply(_ item: PopupMenuItem) {
        guard let session else { return }
        let frame = menuFrame
        close()
        textView?.applyPopupItem(item, session: session, menuFrame: frame)
    }

    /// → на строке с подменю — открыть его и перейти в него; `false` — у строки подменю нет.
    func enterSubmenu() -> Bool {
        guard blockId != nil, let item = selectedItem, item.opensSubmenu else { return false }
        openSubmenu(for: item, focus: true)
        return true
    }

    /// ← и Esc в подменю: фокус обратно в меню, подменю закрывается.
    func leaveSubmenu() {
        closeSubmenu()
    }

    /// Мышь на строке меню блока: строка с подменю открывает его без фокуса, другая — закрывает открытое.
    /// Пока подменю открыто, смена — с задержкой, как у Notion: мышь по пути к подменю задевает соседние строки,
    /// и если к концу задержки она уже в подменю, оно остаётся.
    private func hovered(_ item: PopupMenuItem) {
        guard blockId != nil else { return }
        pendingHover?.cancel()
        guard submenu != nil else {
            if item.opensSubmenu { openSubmenu(for: item, focus: false) }
            return
        }
        guard Self.submenu(for: item) != submenu else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.session != nil, !self.isMouseInSubmenu else { return }
            if item.opensSubmenu { self.openSubmenu(for: item, focus: false) } else { self.closeSubmenu() }
        }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.submenuHoverDelay, execute: work)
    }

    /// Сколько ждать, прежде чем сменить подменю по наведению на другую строку.
    static let submenuHoverDelay: TimeInterval = 0.3

    /// Мышь сейчас над открытым подменю (списком типов или окном цветов).
    private var isMouseInSubmenu: Bool {
        let mouse = NSEvent.mouseLocation
        switch submenu {
        case .turnInto: return kindWindow?.frame.contains(mouse) ?? false
        case .color: return textView?.colorMenu.menuFrame?.insetBy(dx: -PopupMenuWindow.shadowMargin, dy: -PopupMenuWindow.shadowMargin).contains(mouse) ?? false
        case nil: return false
        }
    }

    private static func submenu(for item: PopupMenuItem) -> Submenu? {
        switch item.action {
        case .turnInto: .turnInto
        case .color: .color
        default: nil
        }
    }

    func openSubmenu(for item: PopupMenuItem, focus: Bool) {
        guard let blockId, let textView, let parent = textView.window, let window,
              let kind = Self.submenu(for: item), let row = window.rowFrameOnScreen(item) else { return }
        window.menuView.select(item)
        if submenu != kind { closeSubmenu() }
        submenu = kind
        isSubmenuFocused = focus
        switch kind {
        case .turnInto:
            let list = kindWindow ?? PopupMenuWindow(style: .kindPicker)
            kindWindow = list
            list.menuView.setItems(PopupMenuItem.blockKinds)
            let current = textView.document.blocks.first { $0.id == blockId }.map(\.kind)
            list.menuView.checkedItem = PopupMenuItem.blockKinds.first { $0.action == current.map(PopupMenuItem.Action.setKind) }
            if let checked = list.menuView.checkedItem { list.menuView.select(checked) }
            list.menuView.onChoose = { [weak self] item in self?.apply(item) }
            list.menuView.onHover = { [weak self] _ in self?.isSubmenuFocused = true }
            list.show(besideRow: row, of: window.menuFrame, parent: parent)
        case .color:
            textView.openColorMenu(forBlock: blockId, besideRow: row, of: window.menuFrame)
        }
    }

    func closeSubmenu() {
        pendingHover?.cancel()
        pendingHover = nil
        if submenu == .color { textView?.colorMenu.close() }
        kindWindow?.hide()
        submenu = nil
        isSubmenuFocused = false
    }

    func close() {
        closeSubmenu()
        session = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        window?.hide()
        textView?.popupSessionDidChange()
    }
}

extension PageTextView {
    // MARK: Меню «/» и меню блока

    /// «/» в начале абзаца или после пробела открывает меню типов блоков.
    func openSlashMenuAfterTypedSlash() {
        let caret = selectedRange()
        guard caret.length == 0, caret.location > 0, let position = mapper.blockPosition(at: caret.location) else { return }
        let block = document.blocks[position.index]
        guard block.kind != .pageLink else { return }
        let string = (textStorage?.string ?? "") as NSString
        let slash = caret.location - 1
        let startsWord = position.offset == 1 || Character(UnicodeScalar(string.character(at: slash - 1)) ?? " ").isWhitespace
        guard startsWord else { return }
        // Меню — от левого края «/», а не от курсора за ним: иначе из-под меню торчит начало следующего абзаца.
        let slashOnScreen = firstRect(forCharacterRange: NSRange(location: slash, length: 1), actualRange: nil)
        popups.open(.slash(blockId: block.id, slashLocation: slash), items: PopupMenuItem.slashItems, below: slashOnScreen)
    }

    /// Открыть меню «⋮⋮» у блока, как у Notion: заголовок — тип блока, «Преобразовать в» и «Цвет» — подменю.
    func openBlockMenu(forBlock id: UUID, below anchor: NSRect) {
        guard let block = document.blocks.first(where: { $0.id == id }) else { return }
        popups.open(.block(blockId: id), items: PopupMenuItem.blockMenuItems(for: block.kind), below: anchor,
                    title: PopupMenuItem.blockMenuTitle(of: block.kind))
    }

    /// Щелчок по «⋮⋮», как в Notion: блок выделен целиком (режим блоков) и открыто его меню; Esc закрывает меню,
    /// блок остаётся выделенным.
    func selectBlockAndOpenMenu(_ id: UUID, below anchor: NSRect) {
        window?.makeFirstResponder(self)
        if let index = document.index(ofBlock: id) { selectBlocks(index..<index + 1) }
        openBlockMenu(forBlock: id, below: anchor)
    }

    func textDidChangeForPopups() {
        refreshSlashMenu()
        mediaInsertion.closePastedLinkMenu()
    }

    /// Подсветка и подсказка строки с «/» пересчитываются по курсору: посреди обработки правки раскладка строки
    /// ещё не окончательная и сдвинута на отступ абзаца, а к смене курсора — уже верная.
    func selectionDidChangeForPopups() {
        refreshSlashMenu()
        if popups.isOpen { popupSessionDidChange() }
    }

    /// Меню «/» следует за набором: фильтрует по набранному после «/» и закрывается, если курсор ушёл
    /// из абзаца, «/» стёрт или ничего не подходит.
    private func refreshSlashMenu() {
        guard case .slash(let blockId, let slash)? = popups.session else { return }
        let caret = selectedRange()
        let string = (textStorage?.string ?? "") as NSString
        guard caret.length == 0, slash < string.length, caret.location > slash, string.character(at: slash) == 0x2F,
              let position = mapper.blockPosition(at: caret.location), document.blocks[position.index].id == blockId,
              position.offset >= caret.location - slash else {
            popups.close()
            return
        }
        let query = string.substring(with: NSRange(location: slash + 1, length: caret.location - slash - 1))
        let items = PopupMenuItem.slashItems(matching: query)
        if items.isEmpty { popups.close() } else { popups.update(items: items) }
    }

    /// Стрелки, Enter и Esc, пока открыто меню. В меню блока → входит в подменю, ← и Esc из подменю возвращают в меню;
    /// в окне цветов стрелки — его, ← у левого края и Esc — назад в меню.
    func handlePopupCommand(_ selector: Selector) -> Bool {
        guard popups.isOpen else { return false }
        let isBlockMenu = if case .block? = popups.session { true } else { false }
        if isBlockMenu, popups.submenu == .color, popups.isSubmenuFocused {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                popups.leaveSubmenu()
                return true
            case #selector(NSResponder.moveLeft(_:)) where colorMenu.isSelectionAtRowStart:
                popups.leaveSubmenu()
                return true
            default:
                return false
            }
        }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): popups.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): popups.moveSelection(by: 1)
        case #selector(NSResponder.moveRight(_:)) where isBlockMenu:
            if !popups.isSubmenuFocused { _ = popups.enterSubmenu() }
        case #selector(NSResponder.moveLeft(_:)) where isBlockMenu:
            if popups.isSubmenuFocused { popups.leaveSubmenu() }
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): popups.choose()
        case #selector(NSResponder.cancelOperation(_:)):
            if popups.isSubmenuFocused { popups.leaveSubmenu() } else { popups.close() }
        default: return false
        }
        return true
    }

    func closePopups() { if popups.isOpen { popups.close() } }

    /// Выбор в меню: из меню «/» убирается «/» с набранным поиском, затем меняется тип блока.
    func applyPopupItem(_ item: PopupMenuItem, session: EditorPopupController.Session, menuFrame: NSRect? = nil) {
        let blockId: UUID
        if case .slash(let id, let slash) = session, case .insertDatabase(let inline) = item.action {
            return requestDatabase(fromSlashIn: id, slashLocation: slash, isInline: inline)
        }
        switch session {
        case .slash(let id, let slash) where item.action == .setKind(.pageLink):
            return requestSubpage(fromSlashIn: id, slashLocation: slash)
        case .slash(let id, let slash):
            blockId = id
            let caret = selectedRange().location
            if caret > slash { replaceText(in: NSRange(location: slash, length: caret - slash), with: "") }
        case .block(let id):
            blockId = id
        }
        guard let index = document.index(ofBlock: blockId) else { return }
        switch item.action {
        case .setKind(let kind): setKind(kind, ofBlocksAt: index..<index + 1)
        case .delete: removeBlocks(at: index..<index + 1)
        case .duplicate: duplicateBlocks(at: index..<index + 1)
        case .moveTo:
            // Меню блока внутри выделения действует на всё выделение, как у Notion.
            let range = selectedBlocks.flatMap { $0.contains(index) ? $0 : nil } ?? index..<index + 1
            requestMoveBlocks(range, anchor: menuFrame.map { NSRect(x: $0.minX, y: $0.maxY, width: $0.width, height: 0) })
            return
        case .insertColumns(let count):
            insertColumns(count, at: index)
            return
        case .insertTable:
            insertTable(at: index)
            return
        case .insertDatabase:
            return
        case .color, .turnInto:
            return
        }
        window?.makeFirstResponder(self)
    }

    /// «/» → «Страница», как в Notion: «/» с поиском стирается, пустой блок владелец дерева заменит ссылкой,
    /// у блока с текстом ссылка встанет следующим блоком; новая подстраница сразу открывается.
    /// Стирание — не свой шаг ⌘Z: создание отменяется одним шагом в отмене дерева, а после возврата на страницу
    /// шаг этого редактора вернул бы «/стр» в уже перечитанный блок.
    /// «/База данных — …», как в Notion: «/» с поиском стирается; пустой блок база заменит, после блока с текстом —
    /// встанет следующим блоком. Базу создают операции `Databases` у владельца окна — одним шагом ⌘Z.
    private func requestDatabase(fromSlashIn blockId: UUID, slashLocation slash: Int, isInline: Bool) {
        let caret = selectedRange().location
        if caret > slash {
            undoManager?.disableUndoRegistration()
            replaceText(in: NSRange(location: slash, length: caret - slash), with: "")
            undoManager?.enableUndoRegistration()
        }
        guard let block = document.blocks.first(where: { $0.id == blockId }) else { return }
        onSubpageRequest?(.createDatabase(block.text.string.isEmpty ? .replacing(blockId: blockId) : .after(blockId: blockId), isInline: isInline))
    }

    private func requestSubpage(fromSlashIn blockId: UUID, slashLocation slash: Int) {
        let caret = selectedRange().location
        if caret > slash {
            undoManager?.disableUndoRegistration()
            replaceText(in: NSRange(location: slash, length: caret - slash), with: "")
            undoManager?.enableUndoRegistration()
        }
        guard let block = document.blocks.first(where: { $0.id == blockId }) else { return }
        onSubpageRequest?(.createAndOpen(block.text.string.isEmpty ? .replacing(blockId: blockId) : .after(blockId: blockId)))
    }

    // MARK: Строка с «/»

    /// Меню открылось, сменило список или закрылось: подсказка и подсветка строки с «/» следуют за ним.
    func popupSessionDidChange() {
        updateEmptyParagraphHint()
        updateSlashQueryHighlight()
    }

    /// Где стоит «/» открытого меню «/»; `nil` — меню закрыто или «/» уже стёрт.
    var openSlashLocation: Int? {
        guard case .slash(_, let slash)? = popups.session, slash < (textStorage?.length ?? 0) else { return nil }
        return slash
    }

    /// Строка блока — только «/», курсор сразу за ним: здесь вместо подсказки пустого блока «Начните вводить для поиска».
    func isBareSlashLine(caret location: Int, blockAt index: Int) -> Bool {
        guard case .slash(let blockId, let slash)? = popups.session, document.blocks[index].id == blockId else { return false }
        return location == slash + 1 && document.blocks[index].text.string == "/"
    }

    static let slashQueryHint = "Начните вводить для поиска"

    /// Подсветка hoverBackground под «/» с набранным поиском и подсказкой (contracts/visual-style.md, «Всплывающие меню»).
    private func updateSlashQueryHighlight() {
        let caret = selectedRange()
        guard let slash = openSlashLocation, let window, caret.location > slash else {
            slashQueryHighlight.isHidden = true
            return
        }
        let typedOnScreen = firstRect(forCharacterRange: NSRange(location: slash, length: caret.location - slash), actualRange: nil)
        var frame = convert(window.convertFromScreen(typedOnScreen), from: nil)
        if !emptyParagraphHint.isHidden { frame = frame.union(NSRect(x: frame.minX, y: frame.minY, width: emptyParagraphHint.frame.maxX - frame.minX, height: frame.height)) }
        let padding = Metrics.PopupMenu.slashQueryHorizontalPadding
        slashQueryHighlight.frame = frame.insetBy(dx: -padding, dy: 0)
        slashQueryHighlight.layer?.backgroundColor = resolvedColor(Palette.hoverBackground)
        slashQueryHighlight.isHidden = false
    }
}
