import AppKit
import NotesCore
import VisualStyle

extension NotionColor {
    /// Название цвета в окне цветов.
    var title: String {
        switch self {
        case .gray: "Серый"
        case .brown: "Коричневый"
        case .orange: "Оранжевый"
        case .yellow: "Жёлтый"
        case .green: "Зелёный"
        case .blue: "Синий"
        case .purple: "Фиолетовый"
        case .pink: "Розовый"
        case .red: "Красный"
        }
    }
}

extension ColorChoice {
    /// Строка окна цветов: «Серый текст», «Серый фон», «Текст по умолчанию».
    var title: String {
        switch (target, color) {
        case (.text, nil): "Текст по умолчанию"
        case (.background, nil): "Фон по умолчанию"
        case (.text, let color?): "\(color.title) текст"
        case (.background, let color?): "\(color.title) фон"
        }
    }
}

/// Строка окна цветов: заголовок раздела или цвет.
enum ColorMenuRow: Equatable {
    enum Section: String { case recent, text, background }

    case header(String)
    case choice(ColorChoice, Section)

    /// Строки окна: «Последние» (если есть), все цвета текста, все цвета фона; «По умолчанию» первым в разделе.
    static func rows(recent: [ColorChoice]) -> [ColorMenuRow] {
        var rows: [ColorMenuRow] = []
        if !recent.isEmpty {
            rows.append(.header("Последние"))
            rows += recent.map { .choice($0, .recent) }
        }
        let colors: [NotionColor?] = [nil] + NotionColor.allCases
        rows.append(.header("Цвет текста"))
        rows += colors.map { .choice(ColorChoice(target: .text, color: $0), .text) }
        rows.append(.header("Цвет фона"))
        rows += colors.map { .choice(ColorChoice(target: .background, color: $0), .background) }
        return rows
    }

    var choice: ColorChoice? {
        if case .choice(let choice, _) = self { choice } else { nil }
    }

    var height: CGFloat {
        if case .header = self { Metrics.PopupMenu.sectionHeaderHeight } else { Metrics.PopupMenu.rowHeight }
    }

    var identifier: String {
        switch self {
        case .header(let title): "color-header-\(title)"
        case .choice(let choice, let section): "color-\(section.rawValue)-\(choice.target.rawValue)-\(choice.color?.rawValue ?? "default")"
        }
    }
}

/// Образец цвета: квадрат с буквой «A». Цвет текста — буква цвета на пустом квадрате, цвет фона — квадрат цвета.
@MainActor
enum ColorSwatch {
    static func draw(_ choice: ColorChoice, in rect: NSRect) {
        let radius = Metrics.ColorMenu.swatchCornerRadius
        let tone = choice.color?.tone
        let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let letter: NSColor
        switch choice.target {
        case .text:
            letter = Palette.notionText(tone)
        case .background:
            letter = Palette.textPrimary
            if let fill = Palette.notionBackground(tone) {
                fill.setFill()
                shape.fill()
            }
        }
        Palette.popupDivider.setStroke()
        shape.lineWidth = Metrics.ColorMenu.swatchBorderWidth
        shape.stroke()
        let font = NSFont.systemFont(ofSize: Metrics.ColorMenu.swatchGlyphSize, weight: .medium)
        let glyph = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: letter])
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

/// Строка с цветом: образец и название; выбранная — на фоне hoverBackground.
@MainActor
final class ColorMenuRowView: NSView {
    let choice: ColorChoice
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?

    init(row: ColorMenuRow, choice: ColorChoice) {
        self.choice = choice
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(choice.title)
        setAccessibilityIdentifier(row.identifier)
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
        if isSelected { PopupMenuRowView.drawHighlight(in: bounds) }
        let padding = Metrics.PopupMenu.rowHorizontalPadding
        let side = Metrics.ColorMenu.swatchSize
        ColorSwatch.draw(choice, in: NSRect(x: padding, y: (bounds.height - side) / 2, width: side, height: side))
        let style = Typography.popupMenuTitle
        let textX = padding + side + Metrics.PopupMenu.iconToTitleSpacing
        NSAttributedString(string: choice.title, attributes: [.font: style.font, .foregroundColor: Palette.textPrimary])
            .draw(in: NSRect(x: textX, y: (bounds.height - style.lineHeight) / 2, width: bounds.width - textX - padding, height: style.lineHeight))
    }
}

/// Столбец строк окна цветов; заголовки разделов рисует сам.
@MainActor
final class ColorMenuListView: NSView {
    private(set) var rows: [ColorMenuRow] = []
    private(set) var rowViews: [ColorMenuRowView] = []
    private var headerFrames: [(title: String, frame: NSRect)] = []

    override var isFlipped: Bool { true }

    static func contentHeight(of rows: [ColorMenuRow]) -> CGFloat { rows.reduce(0) { $0 + $1.height } }

    func setRows(_ rows: [ColorMenuRow], onHover: @escaping (Int) -> Void, onClick: @escaping (ColorChoice) -> Void) {
        self.rows = rows
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        headerFrames = []
        let inset = Metrics.PopupMenu.rowInset
        var y: CGFloat = 0
        for row in rows {
            let frame = NSRect(x: inset, y: y, width: Metrics.ColorMenu.width - 2 * inset, height: row.height)
            switch row {
            case .header(let title):
                headerFrames.append((title, frame))
            case .choice(let choice, _):
                let view = ColorMenuRowView(row: row, choice: choice)
                let index = rowViews.count
                view.frame = frame
                view.onHover = { onHover(index) }
                view.onClick = { onClick(choice) }
                addSubview(view)
                rowViews.append(view)
            }
            y += row.height
        }
        setFrameSize(NSSize(width: Metrics.ColorMenu.width, height: y))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = Typography.popupMenuSectionHeader
        for header in headerFrames where header.frame.intersects(dirtyRect) {
            let x = header.frame.minX + Metrics.PopupMenu.rowHorizontalPadding
            NSAttributedString(string: header.title, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary])
                .draw(in: NSRect(x: x, y: header.frame.minY + (header.frame.height - style.lineHeight) / 2,
                                 width: header.frame.maxX - x, height: style.lineHeight))
        }
    }
}

/// Карточка окна цветов с прокручиваемым списком внутри.
@MainActor
final class ColorMenuView: NSView {
    private let scrollView = NSScrollView()
    private let list = ColorMenuListView()
    private(set) var selectedIndex = 0
    var onChoose: ((ColorChoice) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Цвет")
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = list
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var rows: [ColorMenuRow] { list.rows }
    var choices: [ColorChoice] { list.rows.compactMap(\.choice) }
    var selectedChoice: ColorChoice? { choices.indices.contains(selectedIndex) ? choices[selectedIndex] : nil }

    func setRows(_ rows: [ColorMenuRow]) {
        list.setRows(rows, onHover: { [weak self] in self?.select($0, scroll: false) }, onClick: { [weak self] in self?.onChoose?($0) })
        select(0)
        scrollView.contentView.scroll(to: .zero)
        needsLayout = true
    }

    /// Размер карточки; выше `maximumHeight` (и места на экране) не растёт.
    func fittingMenuSize(availableHeight: CGFloat) -> NSSize {
        let padding = 2 * Metrics.PopupMenu.verticalPadding
        let limit = min(Metrics.ColorMenu.maximumHeight, max(availableHeight, 0))
        return NSSize(width: Metrics.ColorMenu.width, height: min(ColorMenuListView.contentHeight(of: rows) + padding, limit))
    }

    private var cardSize = NSSize(width: Metrics.ColorMenu.width, height: Metrics.ColorMenu.maximumHeight)

    func fit(to size: NSSize) {
        cardSize = size
        needsLayout = true
    }

    private var card: NSRect {
        let margin = PopupMenuWindow.shadowMargin
        return NSRect(x: margin, y: margin, width: cardSize.width, height: cardSize.height)
    }

    func moveSelection(by delta: Int) {
        let count = choices.count
        guard count > 0 else { return }
        select((selectedIndex + delta + count) % count, scroll: true)
    }

    func select(_ index: Int, scroll: Bool = true) {
        selectedIndex = index
        for (position, view) in list.rowViews.enumerated() { view.isSelected = position == index }
        if scroll, list.rowViews.indices.contains(index) { list.scrollToVisible(list.rowViews[index].frame) }
    }

    override func layout() {
        super.layout()
        scrollView.frame = card.insetBy(dx: 0, dy: Metrics.PopupMenu.verticalPadding)
        list.setFrameSize(NSSize(width: scrollView.frame.width, height: list.frame.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: card)
    }
}

@MainActor
final class ColorMenuWindow: NSPanel {
    let menuView = ColorMenuView(frame: .zero)

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = menuView
        setAccessibilityIdentifier("color-menu")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Показать на месте `frame` (без тени, координаты экрана).
    func show(menuFrame frame: NSRect, parent: NSWindow) {
        menuView.fit(to: frame.size)
        let margin = PopupMenuWindow.shadowMargin
        setFrame(frame.insetBy(dx: -margin, dy: -margin), display: true)
        PopupWindows.show(self, over: parent)
    }

    var menuFrame: NSRect { frame.insetBy(dx: PopupMenuWindow.shadowMargin, dy: PopupMenuWindow.shadowMargin) }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// Какое окно цветов открыто и что оно красит. Ввод остаётся в тексте страницы: стрелки, Enter и Esc приходят от неё.
@MainActor
final class ColorMenuController {
    enum Target: Equatable {
        /// Выделенный текст.
        case selection
        /// Блок целиком (меню «⋮⋮» → «Цвет»).
        case block(UUID)
    }

    weak var textView: PageTextView?
    private(set) var target: Target?
    private var window: ColorMenuWindow?
    private var deactivationObserver: NSObjectProtocol?

    var isOpen: Bool { target != nil }
    var rows: [ColorMenuRow] { isOpen ? window?.menuView.rows ?? [] : [] }
    var selectedChoice: ColorChoice? { isOpen ? window?.menuView.selectedChoice : nil }
    /// Место окна без тени, в координатах экрана; `nil` — закрыто.
    var menuFrame: NSRect? { isOpen ? window?.menuFrame : nil }

    /// Открыть окно; `place` получает размер окна и видимую область (координаты экрана) и возвращает его место.
    func open(_ target: Target, place: (_ size: NSSize, _ visible: NSRect) -> NSRect) {
        guard let textView, let parent = textView.window else { return }
        let menu = window ?? ColorMenuWindow()
        window = menu
        menu.menuView.onChoose = { [weak self] in self?.choose($0) }
        menu.menuView.setRows(ColorMenuRow.rows(recent: textView.recentColors.choices))
        let visible = parent.screen.map { $0.visibleFrame.intersection(parent.frame) } ?? parent.frame
        let size = menu.menuView.fittingMenuSize(availableHeight: visible.height)
        let frame = place(size, visible)
        self.target = target
        menu.show(menuFrame: frame, parent: parent)
        if deactivationObserver == nil { deactivationObserver = PopupWindows.onAppDeactivation { [weak self] in self?.close() } }
    }

    func close() {
        guard target != nil else { return }
        target = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        window?.hide()
    }

    /// Выбор цвета: окно закрывается, цвет применяется к тому, ради чего оно открыто.
    func choose(_ choice: ColorChoice? = nil) {
        guard let target, let choice = choice ?? selectedChoice else { return }
        close()
        textView?.applyColorChoice(choice, to: target)
    }

    /// Стрелки, Enter и Esc, пока окно открыто.
    func handleCommand(_ selector: Selector) -> Bool {
        guard isOpen, let window else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): window.menuView.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): window.menuView.moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }
}

extension PageTextView {
    /// Применить выбор из окна цветов к выделенному тексту или к блоку.
    func applyColorChoice(_ choice: ColorChoice, to target: ColorMenuController.Target) {
        window?.makeFirstResponder(self)
        switch target {
        case .selection:
            perform(.applyColor(choice))
        case .block(let id):
            guard let index = document.index(ofBlock: id) else { return }
            selectBlocks(index..<index + 1)
            perform(.applyBlockColor(choice))
        }
        updateFormatBar()
    }

    /// Меню блока «⋮⋮» → «Цвет»: окно цветов встаёт на место меню блока `menuFrame` (верхний левый угол) и красит блок.
    func openColorMenu(forBlock id: UUID, replacing menuFrame: NSRect?) {
        colorMenu.open(.block(id)) { size, visible in
            let top = menuFrame?.maxY ?? visible.maxY
            var origin = NSPoint(x: menuFrame?.minX ?? visible.minX, y: top - size.height)
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
            return NSRect(origin: origin, size: size)
        }
    }
}
