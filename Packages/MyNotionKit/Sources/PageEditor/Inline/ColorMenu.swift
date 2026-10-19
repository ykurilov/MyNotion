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

    var identifier: String {
        switch self {
        case .header(let title): "color-header-\(title)"
        case .choice(let choice, let section): "color-\(section.rawValue)-\(choice.target.rawValue)-\(choice.color?.rawValue ?? "default")"
        }
    }
}

/// Раскладка окна цветов, как у Notion 7.39: у каждого раздела заголовок и сетка по `columns` образцов в ряд.
/// Отсчёт — от левого верхнего угла карточки.
struct ColorMenuLayout: Equatable {
    /// Места образцов по порядку `ColorMenuRow.choice`.
    private(set) var swatchFrames: [NSRect] = []
    private(set) var headers: [(title: String, frame: NSRect)] = []
    /// Номера образцов каждого раздела.
    private(set) var sections: [Range<Int>] = []
    private(set) var height: CGFloat = 0

    init(rows: [ColorMenuRow]) {
        typealias M = Metrics.ColorMenu
        var y = M.topPadding
        var column = 0
        var sectionStart = 0
        for row in rows {
            switch row {
            case .header(let title):
                if !swatchFrames.isEmpty {
                    sections.append(sectionStart..<swatchFrames.count)
                    y = (swatchFrames.last?.maxY ?? y) + M.sectionSpacing
                }
                sectionStart = swatchFrames.count
                headers.append((title, NSRect(x: 0, y: y, width: M.width, height: M.sectionHeaderHeight)))
                y += M.sectionHeaderHeight
                column = 0
            case .choice:
                if column == M.columns {
                    column = 0
                    y += M.swatchSize + M.swatchSpacing
                }
                swatchFrames.append(NSRect(x: M.horizontalPadding + CGFloat(column) * (M.swatchSize + M.swatchSpacing), y: y,
                                           width: M.swatchSize, height: M.swatchSize))
                column += 1
            }
        }
        if sectionStart < swatchFrames.count { sections.append(sectionStart..<swatchFrames.count) }
        height = (swatchFrames.last?.maxY ?? y) + M.bottomPadding
    }

    /// Образец после стрелки: ←/→ — соседний по порядку; ↑/↓ — тот же столбец в соседнем ряду, за краем раздела —
    /// в соседнем разделе (по кругу).
    func index(from index: Int, dx: Int, dy: Int) -> Int {
        let count = swatchFrames.count
        guard count > 0 else { return 0 }
        guard dy != 0 else { return (index + dx + count) % count }
        let columns = Metrics.ColorMenu.columns
        guard let sectionIndex = sections.firstIndex(where: { $0.contains(index) }) else { return index }
        let section = sections[sectionIndex]
        let local = index - section.lowerBound
        let column = local % columns
        let row = local / columns + dy
        let rows = (section.count + columns - 1) / columns
        if (0..<rows).contains(row) { return section.lowerBound + min(row * columns + column, section.count - 1) }
        let next = sections[(sectionIndex + (dy > 0 ? 1 : -1) + sections.count) % sections.count]
        let targetRow = dy > 0 ? 0 : (next.count - 1) / columns
        return next.lowerBound + min(targetRow * columns + column, next.count - 1)
    }

    static func == (lhs: ColorMenuLayout, rhs: ColorMenuLayout) -> Bool {
        lhs.swatchFrames == rhs.swatchFrames && lhs.headers.map(\.title) == rhs.headers.map(\.title) && lhs.height == rhs.height
    }
}

/// Образец цвета: квадрат с буквой «A». Цвет текста — буква цвета на пустом квадрате, цвет фона — квадрат цвета.
/// Текущий цвет — кольцо вместо рамки, выбранный стрелками или под мышью — подсветка, как у Notion 7.39.
@MainActor
enum ColorSwatch {
    static func draw(_ choice: ColorChoice, isCurrent: Bool = false, isSelected: Bool = false, in rect: NSRect) {
        typealias M = Metrics.ColorMenu
        let radius = M.swatchCornerRadius
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
        if isSelected {
            Palette.hoverBackground.setFill()
            shape.fill()
        }
        if isCurrent {
            let ring = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            Palette.textPrimary.withAlphaComponent(M.currentRingAlpha).setStroke()
            ring.lineWidth = M.currentRingWidth
            ring.stroke()
        } else {
            let border = tone.map { Palette.notionText($0).withAlphaComponent(M.swatchToneBorderAlpha) } ?? Palette.popupDivider
            border.setStroke()
            shape.lineWidth = M.swatchBorderWidth
            shape.stroke()
        }
        guard choice.target == .text else { return }
        let font = NSFont.systemFont(ofSize: M.swatchGlyphSize, weight: .medium)
        let glyph = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: letter])
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded()))
    }
}

/// Образец в сетке окна цветов; подсказка — название цвета.
@MainActor
final class ColorSwatchView: NSView {
    let choice: ColorChoice
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    /// Текущий цвет того, что красит окно: образец обведён кольцом.
    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            setAccessibilityValue(isCurrent ? "текущий" : nil)
            needsDisplay = true
        }
    }
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?

    init(row: ColorMenuRow, choice: ColorChoice) {
        self.choice = choice
        super.init(frame: .zero)
        toolTip = choice.title
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
        ColorSwatch.draw(choice, isCurrent: isCurrent, isSelected: isSelected, in: bounds)
    }
}

/// Карточка окна цветов: заголовки разделов и сетки образцов (`ColorMenuLayout`).
@MainActor
final class ColorMenuView: NSView {
    private(set) var rows: [ColorMenuRow] = []
    private(set) var gridLayout = ColorMenuLayout(rows: [])
    private(set) var swatches: [ColorSwatchView] = []
    private(set) var selectedIndex = 0
    var onChoose: ((ColorChoice) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("Цвет")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var choices: [ColorChoice] { rows.compactMap(\.choice) }
    var selectedChoice: ColorChoice? { choices.indices.contains(selectedIndex) ? choices[selectedIndex] : nil }

    /// Какие образцы отмечены кольцом как текущий цвет (в «Последних» — никогда).
    private(set) var currentChoices: Set<ColorChoice> = []

    func setRows(_ rows: [ColorMenuRow], current: Set<ColorChoice> = []) {
        self.rows = rows
        gridLayout = ColorMenuLayout(rows: rows)
        swatches.forEach { $0.removeFromSuperview() }
        swatches = rows.compactMap { row -> ColorSwatchView? in
            guard let choice = row.choice else { return nil }
            return ColorSwatchView(row: row, choice: choice)
        }
        for (index, swatch) in swatches.enumerated() {
            swatch.onHover = { [weak self] in self?.select(index) }
            swatch.onClick = { [weak self] in self?.onChoose?(swatch.choice) }
            addSubview(swatch)
        }
        setCurrent(current)
        select(0)
        needsLayout = true
        needsDisplay = true
    }

    /// Отметить кольцом текущие цвета, не трогая разделов (у Notion «Последние» обновляются при следующем открытии).
    func setCurrent(_ current: Set<ColorChoice>) {
        currentChoices = current
        for (row, swatch) in zip(rows.filter { $0.choice != nil }, swatches) {
            if case .choice(let choice, let section) = row { swatch.isCurrent = section != .recent && current.contains(choice) }
        }
    }

    var fittingMenuSize: NSSize { NSSize(width: Metrics.ColorMenu.width, height: gridLayout.height) }

    private var card: NSRect {
        let margin = PopupMenuWindow.shadowMargin
        return NSRect(origin: NSPoint(x: margin, y: margin), size: fittingMenuSize)
    }

    func moveSelection(dx: Int = 0, dy: Int = 0) {
        guard !swatches.isEmpty else { return }
        select(gridLayout.index(from: selectedIndex, dx: dx, dy: dy))
    }

    func select(_ index: Int) {
        selectedIndex = index
        for (position, view) in swatches.enumerated() { view.isSelected = position == index }
    }

    override func layout() {
        super.layout()
        let origin = card.origin
        for (swatch, frame) in zip(swatches, gridLayout.swatchFrames) { swatch.frame = frame.offsetBy(dx: origin.x, dy: origin.y) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = card
        PopupSurface.draw(card: card)
        let style = Typography.popupMenuSectionHeader
        for header in gridLayout.headers {
            let frame = header.frame.offsetBy(dx: card.minX, dy: card.minY)
            let x = frame.minX + Metrics.ColorMenu.sectionHeaderTitleX
            NSAttributedString(string: header.title, attributes: [.font: style.font, .foregroundColor: Palette.textSecondary])
                .draw(in: NSRect(x: x, y: frame.minY + Metrics.ColorMenu.sectionHeaderTitleCenterY - style.lineHeight / 2,
                                 width: frame.maxX - x, height: style.lineHeight))
        }
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
    /// Подписка снимается в `deinit` — он не привязан к главному потоку.
    nonisolated(unsafe) private var deactivationObserver: NSObjectProtocol?

    deinit {
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }

    var isOpen: Bool { target != nil }
    var rows: [ColorMenuRow] { isOpen ? window?.menuView.rows ?? [] : [] }
    var selectedChoice: ColorChoice? { isOpen ? window?.menuView.selectedChoice : nil }
    /// Текущие цвета того, что красит окно: отмечены кольцом.
    var currentChoices: Set<ColorChoice> { isOpen ? window?.menuView.currentChoices ?? [] : [] }
    /// Место окна без тени, в координатах экрана; `nil` — закрыто.
    var menuFrame: NSRect? { isOpen ? window?.menuFrame : nil }

    /// Открыть окно; `place` получает размер окна и видимую область (координаты экрана) и возвращает его место.
    func open(_ target: Target, place: (_ size: NSSize, _ visible: NSRect) -> NSRect) {
        guard let textView, let parent = textView.window else { return }
        let menu = window ?? ColorMenuWindow()
        window = menu
        menu.menuView.onChoose = { [weak self] in self?.choose($0) }
        menu.menuView.setRows(ColorMenuRow.rows(recent: textView.recentColors.choices), current: textView.currentColors(for: target))
        let visible = parent.screen.map { $0.visibleFrame.intersection(parent.frame) } ?? parent.frame
        let size = menu.menuView.fittingMenuSize
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
        textView?.formatBar.colorMenuDidClose()
    }

    /// Выбор цвета: цвет применяется к тому, ради чего окно открыто. Для выделения окно остаётся открытым и кольцо
    /// переходит на новый цвет, как у Notion 7.39; для блока (меню «⋮⋮») — закрывается.
    func choose(_ choice: ColorChoice? = nil) {
        guard let target, let choice = choice ?? selectedChoice, let textView else { return }
        guard target == .selection else {
            close()
            textView.applyColorChoice(choice, to: target)
            return
        }
        textView.applyColorChoice(choice, to: target)
        window?.menuView.setCurrent(textView.currentColors(for: target))
    }

    /// Стрелки, Enter и Esc, пока окно открыто.
    func handleCommand(_ selector: Selector) -> Bool {
        guard isOpen, let window else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): window.menuView.moveSelection(dy: -1)
        case #selector(NSResponder.moveDown(_:)): window.menuView.moveSelection(dy: 1)
        case #selector(NSResponder.moveLeft(_:)): window.menuView.moveSelection(dx: -1)
        case #selector(NSResponder.moveRight(_:)): window.menuView.moveSelection(dx: 1)
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
