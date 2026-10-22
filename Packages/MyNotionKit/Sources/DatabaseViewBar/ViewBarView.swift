import AppKit
import DatabaseGrid
import VisualStyle

/// Строка вида (contracts/database-ui.md, «Строка видов»): слева вкладки видов (у встроенной базы с одним видом их не
/// видно), справа кнопки из реестра `ViewBarItem` — только те, чьё действие дали (US1 — ⤢ и «Создать», US3 — фильтр,
/// сортировка, поиск, настройки).
@MainActor
public final class ViewBarView: NSView {
    public static let height: CGFloat = 40
    public struct Tab: Sendable, Hashable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var tabs: [Tab] = [] { didSet { if tabs != oldValue { rebuild() } } }
    public var activeTabId: UUID? { didSet { needsDisplay = true } }
    public var showsTabs = true { didSet { if showsTabs != oldValue { rebuild() } } }
    /// Действия кнопок по местам; кнопки без действия нет.
    public var actions: [ViewBarSlot: (NSView) -> Void] = [:] { didSet { rebuild() } }
    public var isInline = false { didSet { if isInline != oldValue { rebuild() } } }
    /// Синие значки: фильтр и сортировка вида заданы (Notion — значок синеет).
    public var activeSlots: Set<ViewBarSlot> = [] { didSet { if activeSlots != oldValue { buttons.forEach { $0.needsDisplay = true } } } }
    /// Щелчок по вкладке: неактивная — открыть вид, активная — её меню (как у Notion); правый щелчок — меню.
    public var onSelectTab: ((UUID) -> Void)?
    public var onTabMenu: ((UUID, NSView) -> Void)?
    /// «+» после вкладок — новый вид.
    public var onAddView: ((NSView) -> Void)?
    /// Поиск в базе: текст поля; `nil` — поле закрыто.
    public var onSearchChange: ((String?) -> Void)?
    /// Поле поиска раскрыто (лупа превращается в поле).
    public private(set) var isSearching = false

    private var tabViews: [ViewBarTabView] = []
    private var buttons: [NSView] = []
    private var addViewButton: ViewBarIconButton?
    let searchField = ViewBarSearchField()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("database-view-bar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    private func rebuild() {
        (tabViews + buttons).forEach { $0.removeFromSuperview() }
        addViewButton?.removeFromSuperview()
        tabViews = showsTabs ? tabs.map { tab in
            let view = ViewBarTabView(tab: tab)
            view.isActive = { [weak self] in self?.activeTabId == tab.id }
            view.onPress = { [weak self, weak view] in
                guard let self, let view else { return }
                if activeTabId == tab.id { onTabMenu?(tab.id, view) } else { onSelectTab?(tab.id) }
            }
            view.onMenu = { [weak self, weak view] in
                guard let self, let view else { return }
                onTabMenu?(tab.id, view)
            }
            return view
        } : []
        tabViews.forEach(addSubview)
        if showsTabs, onAddView != nil {
            let button = ViewBarIconButton(symbol: "plus", tooltip: "Новый вид", identifier: "database-view-add")
            button.onPress = { [weak self, weak button] in if let button { self?.onAddView?(button) } }
            addViewButton = button
            addSubview(button)
        } else {
            addViewButton = nil
        }
        buttons = ViewBarItem.ordered(ViewBarItem.all, isInline: isInline).compactMap { item -> NSView? in
            guard let action = actions[item.slot] else { return nil }
            if item.slot == .create {
                let button = CreateRowButton()
                button.onPress = { [weak button] in if let button { action(button) } }
                return button
            }
            if item.slot == .search, isSearching { return searchField }
            let button = ViewBarIconButton(symbol: item.symbol, tooltip: item.tooltip, identifier: "database-view-bar-\(item.slot)")
            button.onPress = { [weak button] in if let button { action(button) } }
            let slot = item.slot
            button.isActive = { [weak self] in self?.activeSlots.contains(slot) == true }
            return button
        }
        buttons.forEach(addSubview)
        needsLayout = true
    }

    /// Лупа раскрывает поле поиска; «×» и Esc на пустом поле его сворачивают.
    public func setSearching(_ searching: Bool, text: String = "") {
        guard searching != isSearching else { return }
        isSearching = searching
        searchField.text = text
        searchField.onChange = { [weak self] text in self?.onSearchChange?(text) }
        searchField.onClose = { [weak self] in
            self?.setSearching(false)
            self?.onSearchChange?(nil)
        }
        rebuild()
        if searching { searchField.focus() }
    }

    public override func layout() {
        super.layout()
        var x: CGFloat = 0
        for tab in tabViews {
            let width = tab.fittingWidth
            tab.frame = NSRect(x: x, y: (bounds.height - 28) / 2, width: width, height: 28)
            x += width + 4
        }
        addViewButton?.frame = NSRect(x: x, y: (bounds.height - 28) / 2, width: 28, height: 28)
        var right = bounds.width
        for button in buttons.reversed() {
            let width = (button as? CreateRowButton)?.fittingWidth ?? (button === searchField ? ViewBarSearchField.width : 28)
            right -= width
            button.frame = NSRect(x: right, y: (bounds.height - 28) / 2, width: width, height: 28)
            right -= button is CreateRowButton ? 8 : 2
        }
    }
}

/// Вкладка вида: значок таблицы и название; активная — на плашке.
@MainActor
final class ViewBarTabView: NSView {
    let tab: ViewBarView.Tab
    var isActive: () -> Bool = { false }
    var onPress: (() -> Void)?
    var onMenu: (() -> Void)?
    private let font = NSFont.systemFont(ofSize: 14, weight: .medium)

    init(tab: ViewBarView.Tab) {
        self.tab = tab
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tab.name)
        setAccessibilityIdentifier("database-view-tab")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    var fittingWidth: CGFloat { 10 + 16 + 6 + (tab.name as NSString).size(withAttributes: [.font: font]).width + 10 }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?() }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let active = isActive()
        if active {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()
        }
        let color = active ? Palette.textPrimary : Palette.textSecondary
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [color]))
        NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)?
            .draw(in: NSRect(x: 10, y: (bounds.height - 13) / 2, width: 16, height: 13))
        let title = NSAttributedString(string: tab.name, attributes: [.font: font, .foregroundColor: color])
        title.draw(at: NSPoint(x: 32, y: (bounds.height - title.size().height) / 2))
    }
}

/// Серая кнопка-значок строки вида; под мышью — подложка.
@MainActor
final class ViewBarIconButton: NSView {
    let symbol: String
    var onPress: (() -> Void)?
    /// Синий значок (фильтр или сортировка заданы).
    var isActive: () -> Bool = { false }
    private var isHovered = false { didSet { needsDisplay = true } }

    init(symbol: String, tooltip: String, identifier: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        toolTip = tooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tooltip)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let color = isActive() ? Palette.activeViewControl : Palette.textSecondary
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(.init(paletteColors: [color]))
        setAccessibilityValue(isActive() ? "активен" : nil)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        image.draw(in: NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2, width: image.size.width,
                              height: image.size.height))
    }
}

/// Синяя «Создать» (Notion «New»): новая строка вверху вида, открывается способом вида.
@MainActor
final class CreateRowButton: NSView {
    var onPress: (() -> Void)?
    static let title = "Создать"
    private let font = NSFont.systemFont(ofSize: 14, weight: .medium)
    private var isPressed = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.title)
        setAccessibilityIdentifier("database-new-row")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    var fittingWidth: CGFloat { (Self.title as NSString).size(withAttributes: [.font: font]).width + 20 }

    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        (isPressed ? Palette.primaryButtonFill.blended(withFraction: 0.15, of: .black) ?? Palette.primaryButtonFill : Palette.primaryButtonFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let title = NSAttributedString(string: Self.title, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = title.size()
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
