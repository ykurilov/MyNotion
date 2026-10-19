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
        /// Только в меню «/»: колонки из N пустых колонок, таблица 3 × 2 (US6).
        case insertColumns(Int)
        case insertTable
    }

    /// Значок строки: короткая надпись, системный значок или квадрат чекбокса.
    enum Icon: Equatable {
        case label(String)
        case symbol(String)
        case checkbox
    }

    var title: String
    var icon: Icon
    var keywords: [String]
    var action: Action

    var identifier: String {
        switch action {
        case .setKind(let kind): kind.rawValue
        case .color: "color"
        case .delete: "delete"
        case .insertColumns(let count): "columns-\(count)"
        case .insertTable: "table"
        }
    }

    /// Быстрые символы типа, как справа в меню «/» у Notion: набранные в начале строки с пробелом, они меняют тип блока.
    var shortcut: String? {
        guard case .setKind(let kind) = action else { return nil }
        return kind.descriptor.markdownShortcuts.first
    }

    /// Типы блоков меню «/» и «Превратить в» — из описателей типов (`BlockKinds/`).
    static var blockKinds: [PopupMenuItem] { BlockKindRegistry.menuItems }

    /// Меню «/»: типы блоков и то, что только вставляется (колонки, таблица).
    static var slashItems: [PopupMenuItem] { blockKinds + BlockKindRegistry.insertMenuItems }

    static let color = PopupMenuItem(title: "Цвет", icon: .symbol("paintpalette"), keywords: [], action: .color)
    static let delete = PopupMenuItem(title: "Удалить", icon: .symbol("trash"), keywords: [], action: .delete)

    /// Меню «/»: поиск по названию и словам-подсказкам без учёта регистра.
    static func slashItems(matching query: String) -> [PopupMenuItem] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return slashItems }
        return slashItems.filter { item in
            item.title.lowercased().contains(query) || item.keywords.contains { $0.hasPrefix(query) }
        }
    }
}

/// Вид меню: «/» — с заголовком раздела, быстрыми символами и строкой «Закрыть меню»; меню блока и список типов
/// панели форматирования — только строки, в списке типов текущий отмечен галочкой.
enum PopupMenuStyle {
    case slash
    case block
    case kindPicker

    var width: CGFloat { self == .slash ? Metrics.PopupMenu.slashMenuWidth : Metrics.PopupMenu.blockMenuWidth }
    var sectionTitle: String? { self == .slash ? "Основные блоки" : nil }
    var hasCloseRow: Bool { self == .slash }
    /// Сколько строк видно без прокрутки. В меню блока «Цвет» и «Удалить» — действия в конце списка: типы блоков
    /// (сколько бы их ни было) и эти две строки видны целиком, прокручивать действия за типы нельзя.
    var maximumVisibleRows: Int { self == .block ? PopupMenuItem.blockKinds.count + 2 : Metrics.PopupMenu.maximumVisibleRows }

    var windowIdentifier: String {
        switch self {
        case .slash: "slash-menu"
        case .block: "block-menu"
        case .kindPicker: "kind-menu"
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

    /// Показать под строкой `anchor` (координаты экрана), а если внизу места нет — над ней.
    /// Невидимое окно страницы (модульные проверки) — только место, на экран меню не выходит.
    func show(below anchor: NSRect, parent: NSWindow) {
        let size = menuView.fittingMenuSize
        let margin = Self.shadowMargin
        let spacing = Metrics.PopupMenu.anchorSpacing
        var origin = NSPoint(x: anchor.minX - margin, y: anchor.minY - spacing - size.height - margin)
        if let screen = parent.screen?.visibleFrame, origin.y + margin < screen.minY {
            origin.y = anchor.maxY + spacing - margin
        }
        setFrame(NSRect(x: origin.x, y: origin.y, width: size.width + 2 * margin, height: size.height + 2 * margin), display: true)
        PopupWindows.show(self, over: parent)
    }

    /// Показать меню на месте `frame` (без тени, координаты экрана).
    func show(menuFrame frame: NSRect, parent: NSWindow) {
        setFrame(frame.insetBy(dx: -Self.shadowMargin, dy: -Self.shadowMargin), display: true)
        PopupWindows.show(self, over: parent)
    }

    /// Место меню без тени, в координатах экрана.
    var menuFrame: NSRect { frame.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin) }

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
    /// Строка «Закрыть меню» внизу меню «/»: мышью закрывает меню, стрелками не выбирается — как у Notion.
    private(set) var footer: PopupMenuFooterView?
    var onChoose: ((PopupMenuItem) -> Void)?
    /// Отмеченная галочкой строка (текущий тип в списке типов).
    var checkedItem: PopupMenuItem? {
        didSet { for row in rows { row.isChecked = row.item == checkedItem } }
    }
    var onClose: (() -> Void)? {
        get { footer?.onClick }
        set { footer?.onClick = newValue }
    }

    init(style: PopupMenuStyle) {
        self.style = style
        super.init(frame: .zero)
        setAccessibilityRole(.menu)
        if style.hasCloseRow {
            let footer = PopupMenuFooterView()
            addSubview(footer)
            self.footer = footer
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var sectionTitle: String? { style.sectionTitle }

    /// От верха меню до первой строки и от последней строки до низа.
    private var rowsTop: CGFloat {
        Metrics.PopupMenu.verticalPadding + (sectionTitle == nil ? 0 : Metrics.PopupMenu.sectionHeaderHeight)
    }

    private var rowsBottom: CGFloat {
        footer == nil ? Metrics.PopupMenu.verticalPadding : Metrics.PopupMenu.rowHeight + Metrics.PopupMenu.bottomPadding
    }

    var fittingMenuSize: NSSize {
        let visibleRows = min(items.count, style.maximumVisibleRows)
        return NSSize(width: style.width, height: rowsTop + CGFloat(visibleRows) * Metrics.PopupMenu.rowHeight + rowsBottom)
    }

    private var menuRect: NSRect {
        let margin = PopupMenuWindow.shadowMargin
        return NSRect(x: margin, y: margin, width: style.width, height: fittingMenuSize.height)
    }

    func setItems(_ items: [PopupMenuItem]) {
        guard items != self.items else { return }
        self.items = items
        selectedIndex = 0
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { index, item in
            let row = PopupMenuRowView(item: item, style: style)
            row.isChecked = item == checkedItem
            row.onHover = { [weak self] in self?.select(index) }
            row.onClick = { [weak self] in self?.onChoose?(item) }
            addSubview(row)
            return row
        }
        layoutRows()
        updateSelection()
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        select((selectedIndex + delta + items.count) % items.count)
    }

    var selectedItem: PopupMenuItem? { items.indices.contains(selectedIndex) ? items[selectedIndex] : nil }

    private func select(_ index: Int) {
        selectedIndex = index
        updateSelection()
    }

    private func updateSelection() {
        for (index, row) in rows.enumerated() { row.isSelected = index == selectedIndex }
        // Выбранная строка видна, даже если строк больше, чем помещается.
        let visible = style.maximumVisibleRows
        let firstVisible = max(0, min(selectedIndex - visible + 1, items.count - visible))
        layoutRows(firstVisible: firstVisible)
    }

    private func layoutRows(firstVisible: Int = 0) {
        let menu = menuRect
        let inset = Metrics.PopupMenu.rowInset
        let height = Metrics.PopupMenu.rowHeight
        for (index, row) in rows.enumerated() {
            let position = index - firstVisible
            row.isHidden = position < 0 || position >= style.maximumVisibleRows
            row.frame = NSRect(x: menu.minX + inset, y: menu.minY + rowsTop + CGFloat(position) * height, width: menu.width - 2 * inset, height: height)
        }
        footer?.frame = NSRect(x: menu.minX + inset, y: menu.maxY - rowsBottom, width: menu.width - 2 * inset, height: height)
    }

    override func layout() {
        super.layout()
        layoutRows()
        updateSelection()
    }

    override func draw(_ dirtyRect: NSRect) {
        let menu = menuRect
        PopupSurface.draw(card: menu)
        guard let sectionTitle else { return }
        let style = Typography.popupMenuSectionHeader
        let x = menu.minX + Metrics.PopupMenu.rowInset + Metrics.PopupMenu.rowHorizontalPadding
        let top = menu.minY + Metrics.PopupMenu.verticalPadding + (Metrics.PopupMenu.sectionHeaderHeight - style.lineHeight) / 2
        NSAttributedString(string: sectionTitle, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary])
            .draw(in: NSRect(x: x, y: top, width: menu.maxX - x, height: style.lineHeight))
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
        if isChecked { textEnd = drawCheckmark() - padding }
        let textX = padding + iconSize + Metrics.PopupMenu.iconToTitleSpacing
        let titleStyle = Typography.popupMenuTitle
        let title = NSAttributedString(string: item.title, attributes: [
            .font: titleStyle.font, .foregroundColor: item.action == .delete ? Palette.destructiveText : Palette.textPrimary,
        ])
        title.draw(in: NSRect(x: textX, y: (bounds.height - titleStyle.lineHeight) / 2, width: textEnd - textX, height: titleStyle.lineHeight))
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
@MainActor
final class EditorPopupController {
    enum Session {
        /// `slashLocation` — где стоит «/» в тексте.
        case slash(blockId: UUID, slashLocation: Int)
        case block(blockId: UUID)
    }

    weak var textView: PageTextView?
    private(set) var session: Session?
    private var window: PopupMenuWindow?
    /// Строка, под которой стоит меню (координаты экрана).
    private var anchor: NSRect = .zero
    /// Приложение ушло в фон — меню закрывается.
    private var deactivationObserver: NSObjectProtocol?

    var isOpen: Bool { session != nil }
    var visibleItems: [PopupMenuItem] { window?.menuView.items ?? [] }
    var selectedItem: PopupMenuItem? { window?.menuView.selectedItem }

    /// Рамка меню без места под тень, в координатах экрана; `nil` — меню закрыто.
    var menuFrame: NSRect? {
        guard isOpen, let window else { return nil }
        let margin = PopupMenuWindow.shadowMargin
        return window.frame.insetBy(dx: margin, dy: margin)
    }

    func open(_ session: Session, items: [PopupMenuItem], below anchor: NSRect) {
        guard let textView, let parent = textView.window else { return }
        let style: PopupMenuStyle = if case .slash = session { .slash } else { .block }
        if window?.menuView.style != style {
            window?.hide()
            window = PopupMenuWindow(style: style)
        }
        self.session = session
        self.anchor = anchor
        guard let window else { return }
        window.menuView.onChoose = { [weak self] item in self?.choose(item) }
        window.menuView.onClose = { [weak self] in self?.close() }
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

    func moveSelection(by delta: Int) { window?.menuView.moveSelection(by: delta) }

    func choose(_ item: PopupMenuItem? = nil) {
        guard let session, let item = item ?? selectedItem else { return }
        let frame = menuFrame
        close()
        textView?.applyPopupItem(item, session: session, menuFrame: frame)
    }

    func close() {
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

    /// Открыть меню «⋮⋮» у блока: сменить тип или удалить.
    func openBlockMenu(forBlock id: UUID, below anchor: NSRect) {
        popups.open(.block(blockId: id), items: PopupMenuItem.blockKinds + [.color, .delete], below: anchor)
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

    /// Стрелки, Enter и Esc, пока открыто меню.
    func handlePopupCommand(_ selector: Selector) -> Bool {
        guard popups.isOpen else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): popups.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): popups.moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): popups.choose()
        case #selector(NSResponder.cancelOperation(_:)): popups.close()
        default: return false
        }
        return true
    }

    func closePopups() { if popups.isOpen { popups.close() } }

    /// Выбор в меню: из меню «/» убирается «/» с набранным поиском, затем меняется тип блока.
    func applyPopupItem(_ item: PopupMenuItem, session: EditorPopupController.Session, menuFrame: NSRect? = nil) {
        let blockId: UUID
        switch session {
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
        case .insertColumns(let count):
            insertColumns(count, at: index)
            return
        case .insertTable:
            insertTable(at: index)
            return
        case .color:
            openColorMenu(forBlock: blockId, replacing: menuFrame)
            return
        }
        window?.makeFirstResponder(self)
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
