import AppKit
import CoreText
import NotesCore
import VisualStyle

/// Строка всплывающего меню блоков: тип блока или «Удалить».
struct PopupMenuItem: Equatable {
    enum Action: Equatable {
        case setKind(BlockKind)
        case delete
    }

    /// Значок строки: короткая надпись, системный значок или квадрат чекбокса.
    enum Icon: Equatable {
        case label(String)
        case symbol(String)
        case checkbox
    }

    var title: String
    var subtitle: String
    var icon: Icon
    var keywords: [String]
    var action: Action

    var identifier: String {
        switch action {
        case .setKind(let kind): kind.rawValue
        case .delete: "delete"
        }
    }

    /// Типы блоков меню «/» и «Превратить в». Подстраница создаётся в боковом дереве (US2), здесь её нет.
    static let blockKinds: [PopupMenuItem] = [
        PopupMenuItem(title: "Текст", subtitle: "Обычный текст", icon: .label("Aa"),
                      keywords: ["text", "paragraph", "абзац", "текст"], action: .setKind(.paragraph)),
        PopupMenuItem(title: "Заголовок 1", subtitle: "Крупный заголовок раздела", icon: .label("H1"),
                      keywords: ["h1", "heading", "#"], action: .setKind(.heading1)),
        PopupMenuItem(title: "Заголовок 2", subtitle: "Средний заголовок", icon: .label("H2"),
                      keywords: ["h2", "heading", "##"], action: .setKind(.heading2)),
        PopupMenuItem(title: "Заголовок 3", subtitle: "Малый заголовок", icon: .label("H3"),
                      keywords: ["h3", "heading", "###"], action: .setKind(.heading3)),
        PopupMenuItem(title: "Маркированный список", subtitle: "Простой список", icon: .symbol("list.bullet"),
                      keywords: ["bullet", "list", "ul", "-", "пункт"], action: .setKind(.bulletItem)),
        PopupMenuItem(title: "Нумерованный список", subtitle: "Список с номерами", icon: .symbol("list.number"),
                      keywords: ["numbered", "ordered", "list", "ol", "1.", "номер"], action: .setKind(.numberedItem)),
        PopupMenuItem(title: "Чекбокс", subtitle: "Список дел с отметками", icon: .checkbox,
                      keywords: ["todo", "to-do", "checkbox", "task", "[]", "дело", "задача"], action: .setKind(.checkbox)),
    ]

    static let delete = PopupMenuItem(title: "Удалить", subtitle: "", icon: .symbol("trash"), keywords: [], action: .delete)

    /// Меню «/»: поиск по названию и словам-подсказкам без учёта регистра.
    static func slashItems(matching query: String) -> [PopupMenuItem] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return blockKinds }
        return blockKinds.filter { item in
            item.title.lowercased().contains(query) || item.keywords.contains { $0.hasPrefix(query) }
        }
    }
}

/// Вид меню: «/» — крупные строки с пояснением, меню блока — короткие строки.
enum PopupMenuStyle {
    case slash
    case block

    var width: CGFloat { self == .slash ? Metrics.PopupMenu.slashMenuWidth : Metrics.PopupMenu.blockMenuWidth }
    var rowHeight: CGFloat { self == .slash ? Metrics.PopupMenu.slashMenuRowHeight : Metrics.PopupMenu.blockMenuRowHeight }
    var iconSize: CGFloat { self == .slash ? Metrics.PopupMenu.slashMenuIconSize : Metrics.PopupMenu.blockMenuIconSize }
    /// Размер шрифта надписи в значке; системные значки и квадрат подгоняются под её высоту.
    var iconGlyphSize: CGFloat { self == .slash ? Metrics.PopupMenu.slashMenuIconGlyphSize : Metrics.PopupMenu.blockMenuIconGlyphSize }
    /// Сторона квадрата, в который вписан рисунок каждого значка.
    var iconInkSize: CGFloat { self == .slash ? Metrics.PopupMenu.slashMenuIconInkSize : Metrics.PopupMenu.blockMenuIconInkSize }
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
        setAccessibilityIdentifier(style == .slash ? "slash-menu" : "block-menu")
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
    var onChoose: ((PopupMenuItem) -> Void)?

    init(style: PopupMenuStyle) {
        self.style = style
        super.init(frame: .zero)
        setAccessibilityRole(.menu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var fittingMenuSize: NSSize {
        let visibleRows = min(items.count, Metrics.PopupMenu.maximumVisibleRows)
        return NSSize(width: style.width, height: CGFloat(visibleRows) * style.rowHeight + 2 * Metrics.PopupMenu.verticalPadding)
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
        let visible = Metrics.PopupMenu.maximumVisibleRows
        let firstVisible = max(0, min(selectedIndex - visible + 1, items.count - visible))
        layoutRows(firstVisible: firstVisible)
    }

    private func layoutRows(firstVisible: Int = 0) {
        let menu = menuRect
        let inset = Metrics.PopupMenu.rowInset
        for (index, row) in rows.enumerated() {
            let position = index - firstVisible
            row.isHidden = position < 0 || position >= Metrics.PopupMenu.maximumVisibleRows
            row.frame = NSRect(x: menu.minX + inset, y: menu.minY + Metrics.PopupMenu.verticalPadding + CGFloat(position) * style.rowHeight,
                               width: menu.width - 2 * inset, height: style.rowHeight)
        }
    }

    override func layout() {
        super.layout()
        layoutRows()
        updateSelection()
    }

    override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: menuRect)
    }
}

/// Строка меню: значок, название и пояснение; выбранная — на фоне hoverBackground.
@MainActor
final class PopupMenuRowView: NSView {
    let item: PopupMenuItem
    let style: PopupMenuStyle
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
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

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Palette.hoverBackground.setFill()
            let radius = Metrics.PopupMenu.rowCornerRadius
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let padding = Metrics.PopupMenu.rowHorizontalPadding
        let iconSize = min(style.iconSize, bounds.height)
        let icon = NSRect(x: padding, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        drawIcon(in: icon)

        let textX = icon.maxX + Metrics.PopupMenu.iconToTitleSpacing
        let titleStyle = Typography.slashMenuTitle
        let title = NSAttributedString(string: item.title, attributes: [
            .font: titleStyle.font, .foregroundColor: item.action == .delete ? Palette.destructiveText : Palette.textPrimary,
        ])
        if style == .slash, !item.subtitle.isEmpty {
            let subtitleStyle = Typography.slashMenuSubtitle
            let subtitle = NSAttributedString(string: item.subtitle, attributes: [
                .font: subtitleStyle.font, .foregroundColor: Palette.textSecondary,
            ])
            let total = titleStyle.lineHeight + subtitleStyle.lineHeight
            let top = (bounds.height - total) / 2
            title.draw(in: NSRect(x: textX, y: top, width: bounds.width - textX - padding, height: titleStyle.lineHeight))
            subtitle.draw(in: NSRect(x: textX, y: top + titleStyle.lineHeight, width: bounds.width - textX - padding,
                                     height: subtitleStyle.lineHeight))
        } else {
            let top = (bounds.height - titleStyle.lineHeight) / 2
            title.draw(in: NSRect(x: textX, y: top, width: bounds.width - textX - padding, height: titleStyle.lineHeight))
        }
    }

    /// Значок типа: в меню «/» — в рамке, как в Notion; в меню блока — без рамки.
    private func drawIcon(in rect: NSRect) {
        if style == .slash {
            let radius = Metrics.PopupMenu.slashMenuIconCornerRadius
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            Palette.popupMenuBackground.setFill()
            box.fill()
            Palette.border.setStroke()
            box.lineWidth = 1
            box.stroke()
        }
        // Одна колонка одной ширины, как в Notion: каждый рисунок вписан в квадрат `iconInkSize` по центру места.
        let side = style.iconInkSize
        let color = item.action == .delete ? Palette.destructiveText : Palette.textPrimary
        switch item.icon {
        case .label(let text):
            let line = BlockDecorationPainter.textLine(text, font: Self.labelFont(for: style))
            let ink = CTLineGetImageBounds(line, nil)
            // Перевёрнутые координаты: середина рисунка надписи выше её базовой линии на `ink.midY`.
            BlockDecorationPainter.drawLine(line, color: color,
                                            baselineOrigin: CGPoint(x: rect.midX - ink.midX, y: rect.midY + ink.midY))
        case .symbol(let name):
            let configuration = NSImage.SymbolConfiguration(pointSize: style.iconGlyphSize, weight: .medium)
                .applying(.init(paletteColors: [color]))
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
                return
            }
            // У картинки значка пустые поля разной ширины: вписывать сам рисунок, а не картинку.
            let ink = Self.inkRect(of: symbol)
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
    private static func inkRect(of image: NSImage) -> NSRect {
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

    /// Шрифт надписей «Aa», «H1»…: один на все, самая широкая надпись — ровно во всю ширину квадрата.
    private static func labelFont(for style: PopupMenuStyle) -> NSFont {
        let base = NSFont.systemFont(ofSize: style.iconGlyphSize, weight: .medium)
        let widest = PopupMenuItem.blockKinds.compactMap { item -> CGFloat? in
            guard case .label(let text) = item.icon else { return nil }
            return CTLineGetImageBounds(BlockDecorationPainter.textLine(text, font: base), nil).width
        }.max() ?? style.iconInkSize
        return NSFont.systemFont(ofSize: style.iconGlyphSize * style.iconInkSize / max(widest, 1), weight: .medium)
    }
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
        close()
        textView?.applyPopupItem(item, session: session)
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
        popups.open(.slash(blockId: block.id, slashLocation: slash), items: PopupMenuItem.blockKinds, below: slashOnScreen)
    }

    /// Открыть меню «⋮⋮» у блока: сменить тип или удалить.
    func openBlockMenu(forBlock id: UUID, below anchor: NSRect) {
        popups.open(.block(blockId: id), items: PopupMenuItem.blockKinds + [.delete], below: anchor)
    }

    func textDidChangeForPopups() { refreshSlashMenu() }

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
    func applyPopupItem(_ item: PopupMenuItem, session: EditorPopupController.Session) {
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

    /// Строка блока — только «/», курсор сразу за ним: здесь вместо подсказки пустого блока «Найти тип блока».
    func isBareSlashLine(caret location: Int, blockAt index: Int) -> Bool {
        guard case .slash(let blockId, let slash)? = popups.session, document.blocks[index].id == blockId else { return false }
        return location == slash + 1 && document.blocks[index].text.string == "/"
    }

    static let slashQueryHint = "Найти тип блока"

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
