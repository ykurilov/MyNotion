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
    /// «▾» у «Создать» — меню шаблонов строк (US6); `nil` — кнопка без «▾».
    public var onCreateMenu: ((NSView) -> Void)? { didSet { rebuild() } }
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
                let button = CreateRowButton(showsMenu: onCreateMenu != nil)
                button.onPress = { [weak button] in if let button { action(button) } }
                button.onMenu = { [weak self] chevron in self?.onCreateMenu?(chevron) }
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
        ViewBarSymbols.image("tablecells", pointSize: 12, weight: .medium, color: color)?
            .draw(in: NSRect(x: 10, y: (bounds.height - 13) / 2, width: 16, height: 13))
        let title = NSAttributedString(string: tab.name, attributes: [.font: font, .foregroundColor: color])
        title.draw(at: NSPoint(x: 32, y: (bounds.height - title.size().height) / 2))
    }
}

/// Значки строки вида, один раз на символ, цвет и оформление: новый `NSImage` при каждой отрисовке заново подбирал
/// представление символа — около 2 мс на открытие вида базы (профиль T085).
@MainActor
enum ViewBarSymbols {
    private struct Key: Hashable {
        let symbol: String
        let pointSize: CGFloat
        let weight: CGFloat
        let color: ObjectIdentifier
        let appearance: NSAppearance.Name
    }

    private static var images: [Key: NSImage] = [:]

    static func image(_ symbol: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let key = Key(symbol: symbol, pointSize: pointSize, weight: weight.rawValue, color: ObjectIdentifier(color),
                      appearance: NSAppearance.currentDrawing().name)
        if let image = images[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight).applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        images[key] = image
        return image
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
        setAccessibilityValue(isActive() ? "активен" : nil)
        guard let image = ViewBarSymbols.image(symbol, pointSize: 13, weight: .regular, color: color) else { return }
        image.draw(in: NSRect(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2, width: image.size.width,
                              height: image.size.height))
    }
}

/// Синяя «Создать» (Notion «New»): новая строка вверху вида, открывается способом вида.
@MainActor
final class CreateRowButton: NSView {
    var onPress: (() -> Void)?
    /// «▾» справа (Notion «New ▾»): меню шаблонов строк.
    var onMenu: ((NSView) -> Void)?
    static let title = "Создать"
    static let chevronWidth: CGFloat = 22
    private let font = NSFont.systemFont(ofSize: 14, weight: .medium)
    private let main = CreateRowButtonPart(label: CreateRowButton.title, identifier: "database-new-row")
    private let chevron: CreateRowButtonPart?

    init(showsMenu: Bool = false) {
        chevron = showsMenu ? CreateRowButtonPart(label: "Шаблоны", identifier: "database-new-row-templates") : nil
        super.init(frame: .zero)
        main.onPress = { [weak self] in self?.onPress?() }
        chevron?.onPress = { [weak self] in if let self, let chevron { onMenu?(chevron) } }
        addSubview(main)
        if let chevron { addSubview(chevron) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    var fittingWidth: CGFloat { (Self.title as NSString).size(withAttributes: [.font: font]).width + 20 + (chevron == nil ? 0 : Self.chevronWidth) }

    override func layout() {
        super.layout()
        let chevronWidth = chevron == nil ? 0 : Self.chevronWidth
        main.frame = NSRect(x: 0, y: 0, width: bounds.width - chevronWidth, height: bounds.height)
        chevron?.frame = NSRect(x: bounds.width - chevronWidth, y: 0, width: chevronWidth, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = main.isPressed || chevron?.isPressed == true
        (pressed ? Palette.primaryButtonFill.blended(withFraction: 0.15, of: .black) ?? Palette.primaryButtonFill : Palette.primaryButtonFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let title = NSAttributedString(string: Self.title, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = title.size()
        title.draw(at: NSPoint(x: (main.frame.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        guard let chevron else { return }
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSRect(x: chevron.frame.minX, y: 6, width: 1, height: bounds.height - 12).fill()
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        guard let image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: chevron.frame.midX - image.size.width / 2, y: (bounds.height - image.size.height) / 2,
                               width: image.size.width, height: image.size.height))
    }
}

/// Часть кнопки «Создать ▾»: сама кнопка или «▾»; рисует её родитель.
private final class CreateRowButtonPart: NSView {
    var onPress: (() -> Void)?
    private(set) var isPressed = false { didSet { superview?.needsDisplay = true } }

    init(label: String, identifier: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
