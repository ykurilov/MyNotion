#if canImport(AppKit)
import AppKit

/// Строка меню действий — меню «•••» страницы и меню строки боковой панели (contracts/visual-style.md,
/// «Всплывающие меню»). Как у Notion 7.39 (замер дерева страницы 21.10.2026): пункт 28 с шагом 29 в 4 от краёв карточки,
/// значок 20 в 8 от края пункта, название в 36, подсказка клавиш и «›» — в 8 от правого края пункта; черта между группами.
public enum ActionMenuEntry {
    /// Пункт: `hint` — серая подсказка клавиш справа; `opensSubmenu` — «›» справа, наведение открывает подменю.
    case action(ActionMenuAction)
    /// Поле «Найти действие…» сверху: сужает меню до пунктов с запросом в названии.
    case search(placeholder: String, identifier: String?)
    /// Серая строка внизу.
    case footer(String, identifier: String?)
    case separator
}

/// Пункт меню действий.
public struct ActionMenuAction {
    public let title: String
    /// Имя значка SF Symbols.
    public let icon: String?
    public let hint: String?
    public let opensSubmenu: Bool
    /// «›» справа без подменю по наведению: пункт открывает окно щелчком («Изменить свойство ›» меню колонки).
    public let showsChevron: Bool
    public let identifier: String?
    /// Выбор пункта; для пункта с подменю `row` — его строка (подменю встаёт у неё).
    public let perform: @MainActor (_ row: NSView) -> Void

    public init(title: String, icon: String?, hint: String? = nil, opensSubmenu: Bool = false, showsChevron: Bool = false,
                identifier: String? = nil, perform: @escaping @MainActor (_ row: NSView) -> Void) {
        self.title = title
        self.icon = icon
        self.hint = hint
        self.opensSubmenu = opensSubmenu
        self.showsChevron = showsChevron
        self.identifier = identifier
        self.perform = perform
    }
}

/// Строки меню действий в карточке (`PopupCard`): поле поиска, пункты, черты, подвал.
@MainActor
public final class ActionMenuView: NSView, NSSearchFieldDelegate {
    private let width: CGFloat
    private var searchField: ActionMenuSearchField?
    private var entries: [(row: NSView, title: String?)] = []
    /// Выбран обычный пункт: карточку пора закрыть.
    public var onChoose: (() -> Void)?
    /// Запрос в поле поиска сменился (подменю закрывается).
    public var onFilter: (() -> Void)?

    public init(entries: [ActionMenuEntry], width: CGFloat) {
        self.width = width
        super.init(frame: .zero)
        for entry in entries {
            switch entry {
            case .separator:
                self.entries.append((ActionMenuSeparatorView(), nil))
            case .search(let placeholder, let identifier):
                let field = ActionMenuSearchField(placeholder: placeholder)
                field.field.delegate = self
                if let identifier { field.field.setAccessibilityIdentifier(identifier) }
                searchField = field
                self.entries.append((field, nil))
            case .footer(let text, let identifier):
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: Typography.popupMenuShortcut.fontSize)
                label.textColor = Palette.textSecondary
                label.lineBreakMode = .byTruncatingTail
                if let identifier { label.setAccessibilityIdentifier(identifier) }
                self.entries.append((label, nil))
            case .action(let action):
                let row = ActionMenuRowView(action)
                row.onPress = { [weak self, weak row] in
                    guard let self, let row else { return }
                    // Карточка закрывается до действия: окно, которое оно откроет («Переместить в»), остаётся главным.
                    if !action.opensSubmenu { self.onChoose?() }
                    action.perform(row)
                }
                if action.opensSubmenu { row.onHover = { [weak row] in row?.press() } }
                self.entries.append((row, action.title))
            }
        }
        self.entries.forEach { addSubview($0.row) }
        frame.size = fittingSize
        layoutRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override public var isFlipped: Bool { true }

    override public var fittingSize: NSSize {
        let height = entries.filter { !$0.row.isHidden }.reduce(2 * Metrics.PopupMenu.verticalPadding) { $0 + Self.height(of: $1.row) }
        return NSSize(width: width, height: height)
    }

    private static func height(of row: NSView) -> CGFloat {
        switch row {
        case is ActionMenuSeparatorView: Metrics.PopupMenu.groupSeparatorHeight
        case is ActionMenuSearchField: Metrics.ActionMenu.searchBlockHeight
        default: Metrics.PopupMenu.compactRowHeight
        }
    }

    private func layoutRows() {
        var y = Metrics.PopupMenu.verticalPadding
        let inset = Metrics.PopupMenu.rowInset
        for (row, _) in entries where !row.isHidden {
            let height = Self.height(of: row)
            switch row {
            case is ActionMenuSearchField:
                let side = Metrics.ActionMenu.searchInset
                row.frame = NSRect(x: side, y: y + Metrics.ActionMenu.searchTopOffset, width: bounds.width - 2 * side,
                                   height: Metrics.ActionMenu.searchHeight)
            case is NSTextField:
                let x = inset + Metrics.PopupMenu.rowHorizontalPadding
                row.frame = NSRect(x: x, y: y + (height - 16) / 2, width: bounds.width - 2 * x, height: 16)
            default:
                row.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: height)
            }
            y += height
        }
    }

    override public func layout() {
        super.layout()
        layoutRows()
    }

    public func focusSearch() {
        if let searchField { window?.makeFirstResponder(searchField.field) }
    }

    public func controlTextDidChange(_ notification: Notification) {
        filter(searchField?.field.stringValue ?? "")
    }

    /// Оставить пункты, в названии которых есть запрос; при запросе черты и подвал прячутся.
    public func filter(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        onFilter?()
        for (row, title) in entries where !(row is ActionMenuSearchField) {
            if let title {
                row.isHidden = !query.isEmpty && title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil
            } else {
                row.isHidden = !query.isEmpty
            }
        }
        needsLayout = true
    }

    /// Названия видимых пунктов — для проверок.
    public var visibleTitles: [String] { entries.filter { !$0.row.isHidden }.compactMap(\.title) }

    /// Пункты и черты по порядку («—» — черта) — для проверок.
    public var outline: [String] {
        entries.compactMap { entry in
            if let title = entry.title { return title }
            return entry.row is ActionMenuSeparatorView ? "—" : nil
        }
    }

    /// Строки пунктов.
    public var rowViews: [ActionMenuRowView] { entries.compactMap { $0.row as? ActionMenuRowView } }

    /// Поле поиска, если есть.
    public var searchBox: ActionMenuSearchField? { searchField }

    // MARK: Клавиши

    /// Подсвеченный пункт среди видимых (мышью или стрелками).
    public var highlightedRow: ActionMenuRowView? { rowViews.first { !$0.isHidden && $0.isHovered } }

    /// Стрелка ↑↓: подсветка на соседний видимый пункт, по кругу (как у меню «/» 002).
    public func moveHighlight(by delta: Int) {
        let rows = rowViews.filter { !$0.isHidden }
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.isHovered }
        let next = current.map { ($0 + (delta > 0 ? 1 : -1) + rows.count) % rows.count } ?? (delta > 0 ? 0 : rows.count - 1)
        rowViews.forEach { $0.isHovered = false }
        rows[next].isHovered = true
    }

    /// Enter: выбрать подсвеченный пункт; `false` — подсветки нет.
    @discardableResult
    public func pressHighlighted() -> Bool {
        guard let row = highlightedRow else { return false }
        row.press()
        return true
    }
}

/// Пункт меню: значок, название, серая подсказка или «›» справа, подложка под мышью.
@MainActor
public final class ActionMenuRowView: NSView {
    public let action: ActionMenuAction
    var onPress: (() -> Void)?
    var onHover: (() -> Void)?
    public internal(set) var isHovered = false { didSet { needsDisplay = true } }

    init(_ action: ActionMenuAction) {
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(action.title)
        if let identifier = action.identifier { setAccessibilityIdentifier(identifier) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override public var isFlipped: Bool { true }

    /// Сам пункт — верхние 28 из шага 29 (между пунктами 1, как у Notion): подложка, значок и текст — по его середине.
    public var itemRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, Metrics.ActionMenu.highlightHeight)) }

    /// Место значка: квадрат 20 в 8 от левого края пункта, по середине пункта.
    public var iconRect: NSRect {
        let side = Metrics.PopupMenu.iconSize
        return NSRect(x: Metrics.PopupMenu.rowHorizontalPadding, y: ((itemRect.height - side) / 2).rounded(), width: side, height: side)
    }

    /// Левый край названия.
    public var titleX: CGFloat { Metrics.PopupMenu.rowHorizontalPadding + Metrics.PopupMenu.iconSize + Metrics.PopupMenu.iconToTitleSpacing }

    /// Место «›»: квадрат 16 в 8 от правого края пункта.
    public var chevronRect: NSRect {
        let side = Metrics.ActionMenu.chevronSize
        return NSRect(x: bounds.maxX - Metrics.PopupMenu.rowHorizontalPadding - side, y: ((itemRect.height - side) / 2).rounded(),
                      width: side, height: side)
    }

    private var hintText: NSAttributedString? {
        action.hint.map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: Typography.popupMenuShortcut.fontSize),
                                                         .foregroundColor: Palette.textSecondary])
        }
    }

    /// Подсказка клавиш: правым краем в 8 от правого края пункта; ширина — по рисунку, с запасом на округление.
    public var hintRect: NSRect? {
        guard let hintText else { return nil }
        let width = hintText.size().width
        let lineHeight = Typography.popupMenuShortcut.lineHeight
        return NSRect(x: bounds.maxX - Metrics.PopupMenu.rowHorizontalPadding - width, y: (itemRect.height - lineHeight) / 2,
                      width: width, height: lineHeight)
    }

    override public func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: itemRect, xRadius: Metrics.PopupMenu.rowCornerRadius, yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        if let icon = action.icon { ActionMenuIcon.draw(icon, color: Palette.textPrimary, in: iconRect) }
        var titleEnd = bounds.maxX - Metrics.PopupMenu.rowHorizontalPadding
        if action.opensSubmenu || action.showsChevron {
            ActionMenuIcon.drawChevron(in: chevronRect)
            titleEnd = chevronRect.minX - Metrics.PopupMenu.rowHorizontalPadding
        } else if let hintText, let hintRect {
            // От точки, а не в рамку: рамка по ширине текста обрезала бы последний знак («⌘D»).
            hintText.draw(at: hintRect.origin)
            titleEnd = hintRect.minX - Metrics.PopupMenu.rowHorizontalPadding
        }
        let style = Typography.popupMenuTitle
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: action.title, attributes: [.font: style.font, .foregroundColor: Palette.textPrimary, .paragraphStyle: paragraph])
            .draw(in: NSRect(x: titleX, y: (itemRect.height - style.lineHeight) / 2, width: max(0, titleEnd - titleX), height: style.lineHeight))
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override public func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?()
    }
    override public func mouseExited(with event: NSEvent) { isHovered = false }
    override public func mouseDown(with event: NSEvent) {}
    override public func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    public func press() { onPress?() }

    override public func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}

/// Черта между группами: от 12 до 12 от краёв карточки, посередине своих 8.
final class ActionMenuSeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Palette.border.setFill()
        NSRect(x: Metrics.PopupMenu.rowHorizontalPadding, y: bounds.midY, width: bounds.width - 2 * Metrics.PopupMenu.rowHorizontalPadding, height: 1).fill()
    }
}

/// Поле «Найти действие…»: скругление 6, лупа слева, синяя рамка, пока в поле фокус (как поле «Переместить в»).
@MainActor
public final class ActionMenuSearchField: NSView {
    public let field = FocusReportingSearchField()

    init(placeholder: String) {
        super.init(frame: .zero)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.popupMenuTitle.font
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        field.onFocusChange = { [weak self] in self?.needsDisplay = true }
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override public var isFlipped: Bool { true }

    /// Фокус в поле.
    public var isFocused: Bool { field.hasFocus }

    override public func layout() {
        super.layout()
        let x = Metrics.ActionMenu.searchTextX
        field.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: bounds.width - x - 8, height: 20)
    }

    override public func draw(_ dirtyRect: NSRect) {
        let radius = Metrics.ActionMenu.searchCornerRadius
        let box = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        Palette.emojiSearchBackground.setFill()
        path.fill()
        if isFocused {
            path.lineWidth = Metrics.ActionMenu.focusRingWidth
            Palette.focusRing.setStroke()
        } else {
            path.lineWidth = 1
            Palette.searchFieldBorder.setStroke()
        }
        path.stroke()
        let side = Metrics.ActionMenu.searchIconSize
        ActionMenuIcon.draw("magnifyingglass", color: Palette.textSecondary,
                            in: NSRect(x: (Metrics.ActionMenu.searchTextX - side) / 2 + 1, y: (bounds.height - side) / 2, width: side, height: side),
                            inkSide: side - 2)
    }
}

/// Поле поиска, которое сообщает, что получило или потеряло фокус (рамка поля перерисовывается).
public final class FocusReportingSearchField: NSSearchField {
    var onFocusChange: (() -> Void)?

    var hasFocus: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return editor.delegate as? NSSearchField === self
    }

    override public func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.onFocusChange?() }
        return result
    }

    override public func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?()
    }
}

/// Значки меню: рисунок SF Symbols вписан в квадрат по центру места значка (у картинок символов поля разной ширины).
@MainActor
public enum ActionMenuIcon {
    private static var inkCache: [String: NSRect] = [:]

    public static func draw(_ name: String, color: NSColor, in rect: NSRect, inkSide: CGFloat = Metrics.PopupMenu.iconInkSize) {
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.PopupMenu.iconGlyphSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let ink = inkCache[name] ?? inkRect(of: symbol)
        inkCache[name] = ink
        let scale = inkSide / max(ink.width, ink.height, 1)
        let origin = CGPoint(x: rect.midX - ink.midX * scale, y: rect.midY - ink.midY * scale)
        symbol.draw(in: NSRect(x: origin.x, y: origin.y, width: symbol.size.width * scale, height: symbol.size.height * scale),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// «›» подменю: серый, рисунок 10 по высоте в квадрате 16.
    public static func drawChevron(in rect: NSRect) {
        draw("chevron.right", color: Palette.textSecondary, in: rect, inkSide: Metrics.ActionMenu.chevronInkHeight)
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
        return NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }
}
#endif
