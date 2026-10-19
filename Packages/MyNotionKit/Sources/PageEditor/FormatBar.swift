import AppKit
import NotesCore
import VisualStyle

/// Кнопка панели форматирования (FR-033), слева направо.
public enum FormatBarButton: String, CaseIterable, Sendable {
    case bold
    case italic
    case underline
    case strikethrough
    case code
    /// «√x» — формула в строке (US4).
    case equation
    case link
    case color

    var title: String {
        switch self {
        case .bold: "Жирный"
        case .italic: "Курсив"
        case .underline: "Подчёркнутый"
        case .strikethrough: "Зачёркнутый"
        case .code: "Код"
        case .equation: "Формула"
        case .link: "Ссылка"
        case .color: "Цвет"
        }
    }

    var symbolName: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .equation: "x.squareroot"
        case .link: "link"
        case .color: "textformat"
        }
    }

    /// Оформление кнопки; у ссылки — окно адреса.
    var format: InlineFormat? {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .underline: .underline
        case .strikethrough: .strikethrough
        case .code: .code
        case .equation, .link, .color: nil
        }
    }
}

/// Что показывает панель: тип выделенных блоков (`nil` — разные) и нажатые кнопки.
struct FormatBarState: Equatable {
    var kind: BlockKind?
    var active: Set<FormatBarButton>
    /// Последний применённый цвет: кнопка «A» подчёркнута им.
    var lastColor: ColorChoice? = nil

    var kindItem: PopupMenuItem? {
        kind.flatMap { kind in PopupMenuItem.blockKinds.first { $0.action == .setKind(kind) } }
    }

    /// Как «Multiple Types» у Notion, когда выделены блоки разных типов.
    var kindTitle: String { kindItem?.title ?? "Разные типы" }
    var kindIcon: PopupMenuItem.Icon { kindItem?.icon ?? .symbol("square.stack") }
}

/// Панель форматирования над выделенным текстом (contracts/editor-interactions.md, «Панель форматирования»):
/// окно без рамки, ввод остаётся в тексте страницы.
@MainActor
final class FormatBarWindow: NSPanel {
    static let shadowMargin: CGFloat = PopupMenuWindow.shadowMargin
    let barView = FormatBarView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = barView
        setAccessibilityIdentifier("format-bar")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Карточка с местом `card` (координаты экрана). Невидимое окно страницы — на экран не выходит.
    func show(card: NSRect, parent: NSWindow) {
        let margin = Self.shadowMargin
        setFrame(card.insetBy(dx: -margin, dy: -margin), display: true)
        PopupWindows.show(self, over: parent)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// Карточка панели: строка типа блока со стрелкой «›», разделитель, ряд кнопок (contracts/visual-style.md,
/// «Панель форматирования»).
@MainActor
final class FormatBarView: NSView {
    let kindRow = FormatBarKindRowView()
    private(set) var buttons: [FormatBarButtonView] = []
    var state = FormatBarState(kind: .paragraph, active: []) {
        didSet {
            guard state != oldValue else { return }
            kindRow.state = state
            for button in buttons {
                button.isActive = state.active.contains(button.button)
                button.lastColor = state.lastColor
            }
        }
    }
    var onKind: (() -> Void)? {
        get { kindRow.onClick }
        set { kindRow.onClick = newValue }
    }
    var onButton: ((FormatBarButton) -> Void)?

    init() {
        super.init(frame: .zero)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Форматирование")
        kindRow.state = state
        addSubview(kindRow)
        buttons = FormatBarButton.allCases.map { button in
            let view = FormatBarButtonView(button: button)
            view.onClick = { [weak self] in self?.onButton?(button) }
            addSubview(view)
            return view
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var card: NSRect {
        let margin = FormatBarWindow.shadowMargin
        return NSRect(x: margin, y: margin, width: Metrics.FormatBar.width, height: Metrics.FormatBar.height)
    }

    override func layout() {
        super.layout()
        let card = card
        let inset = Metrics.PopupMenu.rowInset
        kindRow.frame = NSRect(x: card.minX + inset, y: card.minY + Metrics.FormatBar.verticalPadding,
                               width: card.width - 2 * inset, height: Metrics.FormatBar.kindRowHeight)
        let rowTop = kindRow.frame.maxY + Metrics.FormatBar.dividerBandHeight
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: card.minX + Metrics.FormatBar.horizontalPadding + CGFloat(index) * Metrics.FormatBar.buttonWidth,
                                  y: rowTop, width: Metrics.FormatBar.buttonWidth, height: Metrics.FormatBar.buttonRowHeight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = card
        PopupSurface.draw(card: card)
        Palette.popupDivider.setFill()
        let y = card.minY + Metrics.FormatBar.verticalPadding + Metrics.FormatBar.kindRowHeight + Metrics.FormatBar.dividerOffset
        let inset = Metrics.FormatBar.dividerInset
        NSRect(x: card.minX + inset, y: y, width: card.width - 2 * inset, height: Metrics.FormatBar.dividerWidth).fill()
    }
}

/// Нажатие мышью внутри вида: по отпусканию над ним, как у строк меню; подсветка под мышью.
@MainActor
class FormatBarControlView: NSView {
    var onClick: (() -> Void)?
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

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
}

/// Строка типа: значок и название типа выделенных блоков, справа серая «›»; щелчок открывает список типов.
@MainActor
final class FormatBarKindRowView: FormatBarControlView {
    var state = FormatBarState(kind: .paragraph, active: []) {
        didSet {
            setAccessibilityLabel(state.kindTitle)
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityIdentifier("format-kind")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered { PopupMenuRowView.drawHighlight(in: bounds) }
        // Места — от края карточки: строка отступает от него на rowInset.
        let inset = Metrics.PopupMenu.rowInset
        let iconSize = Metrics.PopupMenu.iconSize
        PopupMenuRowView.drawIcon(state.kindIcon, color: Palette.textPrimary,
                                  in: NSRect(x: Metrics.FormatBar.kindIconCenterX - inset - iconSize / 2, y: (bounds.height - iconSize) / 2,
                                             width: iconSize, height: iconSize))

        let chevronX = bounds.maxX - (Metrics.FormatBar.kindChevronCenterFromRight - inset)
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.FormatBar.kindChevronGlyphSize, weight: .regular)
            .applying(.init(paletteColors: [Palette.textSecondary]))
        var textEnd = bounds.maxX
        if let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let size = chevron.size
            chevron.draw(in: NSRect(x: chevronX - size.width / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            textEnd = chevronX - size.width
        }

        let titleStyle = Typography.popupMenuTitle
        let textX = Metrics.FormatBar.kindTitleX - inset
        NSAttributedString(string: state.kindTitle, attributes: [.font: titleStyle.font, .foregroundColor: Palette.textPrimary])
            .draw(in: NSRect(x: textX, y: (bounds.height - titleStyle.lineHeight) / 2, width: textEnd - textX, height: titleStyle.lineHeight))
    }
}

/// Кнопка оформления: системный значок по центру места; нажатая — синий значок, как у Notion.
@MainActor
final class FormatBarButtonView: FormatBarControlView {
    let button: FormatBarButton
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            setAccessibilitySelected(isActive)
            needsDisplay = true
        }
    }
    /// Последний цвет: подчёркивает кнопку «A».
    var lastColor: ColorChoice? { didSet { if lastColor != oldValue, button == .color { needsDisplay = true } } }
    private let symbol: NSImage?
    /// Где в картинке значка сам рисунок: значок ставится по центру рисунка, а не картинки.
    private let ink: NSRect

    init(button: FormatBarButton) {
        self.button = button
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.FormatBar.buttonGlyphSize, weight: .regular)
        symbol = NSImage(systemSymbolName: button.symbolName, accessibilityDescription: button.title)?.withSymbolConfiguration(configuration)
        ink = symbol.map(PopupMenuRowView.inkRect(of:)) ?? .zero
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(button.title)
        setAccessibilityIdentifier("format-\(button.rawValue)")
        setAccessibilitySelected(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            let size = Metrics.FormatBar.buttonHighlightSize
            let radius = Metrics.FormatBar.buttonCornerRadius
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height),
                         xRadius: radius, yRadius: radius).fill()
        }
        if button == .color {
            drawColorGlyph()
            return
        }
        guard let symbol else { return }
        let color = isActive ? Palette.formatBarActiveIcon : Palette.textPrimary
        let tinted = symbol.withSymbolConfiguration(.init(paletteColors: [color])) ?? symbol
        // Широкие значки («</>») уменьшаются, чтобы рисунок влез в рамку, как у Notion.
        let box = Metrics.FormatBar.buttonInkBox
        let scale = min(1, box.width / max(ink.width, 1), box.height / max(ink.height, 1))
        let origin = NSPoint(x: (bounds.midX - ink.midX * scale).rounded(), y: (bounds.midY - ink.midY * scale).rounded())
        tinted.draw(in: NSRect(x: origin.x, y: origin.y, width: symbol.size.width * scale, height: symbol.size.height * scale),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension FormatBarButtonView {
    /// Кнопка цвета: буква «A» по центру места и под ней черта последнего цвета (текста или фона).
    fileprivate func drawColorGlyph() {
        let font = NSFont.systemFont(ofSize: Metrics.FormatBar.buttonGlyphSize, weight: .medium)
        let glyph = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: Palette.textPrimary])
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded()))
        guard let lastColor, let tone = lastColor.color?.tone else { return }
        let fill = lastColor.target == .text ? Palette.notionText(tone) : Palette.notionBackground(tone)
        let line = Metrics.ColorMenu.barUnderlineSize
        fill?.setFill()
        let y = (bounds.midY + font.capHeight / 2 + Metrics.ColorMenu.barUnderlineSpacing).rounded()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - line.width / 2, y: y, width: line.width, height: line.height),
                     xRadius: line.height / 2, yRadius: line.height / 2).fill()
    }
}

/// Показывает и прячет панель, открывает список типов. Панель живёт, пока в тексте страницы выделен текст.
@MainActor
final class FormatBarController {
    weak var textView: PageTextView?
    private(set) var state: FormatBarState?
    /// Место карточки без тени, в координатах экрана; `nil` — панель скрыта.
    private(set) var cardFrame: NSRect?
    /// Где панель поставлена для текущего выделения; пока выделение то же, панель на месте (как в Notion).
    var anchor: FormatBarAnchor?
    private var window: FormatBarWindow?
    private var kindMenu: PopupMenuWindow?
    private var observers: [NSObjectProtocol] = []

    var isShown: Bool { state != nil }
    var isKindMenuOpen: Bool { kindMenu != nil }
    var kindMenuItems: [PopupMenuItem] { kindMenu?.menuView.items ?? [] }
    var checkedKindItem: PopupMenuItem? { kindMenu?.menuView.checkedItem }
    /// Место открытого списка типов без тени, в координатах экрана.
    var kindMenuFrame: NSRect? { kindMenu?.menuFrame }

    /// Показать под строкой выделения `line`, левым краем у `anchorX` (см. `FormatBarPlacement`).
    /// Все места — в координатах экрана.
    func show(_ state: FormatBarState, line: NSRect, anchorX: CGFloat, visible: NSRect) {
        guard let parent = textView?.window else { return }
        let size = NSSize(width: Metrics.FormatBar.width, height: Metrics.FormatBar.height)
        let card = FormatBarPlacement.card(size: size, line: line, anchorX: anchorX, visible: visible)

        let window = window ?? makeWindow()
        self.state = state
        window.barView.state = state
        if card != cardFrame || window.parent == nil {
            cardFrame = card
            window.show(card: card, parent: parent)
        }
        kindMenu?.menuView.checkedItem = state.kindItem
        if observers.isEmpty { observe() }
    }

    func hide() {
        closeKindMenu()
        if textView?.colorMenu.target == .selection { textView?.colorMenu.close() }
        state = nil
        cardFrame = nil
        anchor = nil
        window?.hide()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    func press(_ button: FormatBarButton) {
        guard isShown, let textView else { return }
        guard button != .color else {
            toggleColorMenu()
            return
        }
        closeKindMenu()
        textView.colorMenu.close()
        if button == .equation {
            hide()
            textView.perform(.insertInlineEquation)
            return
        }
        guard let format = button.format else {
            hide()
            textView.editLink(nil)
            return
        }
        textView.perform(.toggleInline(format))
        textView.updateFormatBar()
    }

    // MARK: Список типов

    func openKindMenu() {
        guard let state, let window, let parent = textView?.window else { return }
        textView?.colorMenu.close()
        let menu = kindMenu ?? PopupMenuWindow(style: .kindPicker)
        kindMenu = menu
        menu.menuView.setItems(PopupMenuItem.blockKinds)
        menu.menuView.checkedItem = state.kindItem
        menu.menuView.onChoose = { [weak self] item in
            if case .setKind(let kind) = item.action { self?.chooseKind(kind) }
        }
        let row = window.barView.kindRow
        let rowOnScreen = window.convertToScreen(row.convert(row.bounds, to: nil))
        guard let card = cardFrame else { return }
        let frame = FormatBarPlacement.kindMenu(size: menu.menuView.fittingMenuSize, card: card, row: rowOnScreen,
                                                visible: parent.screen.map { $0.visibleFrame.intersection(parent.frame) } ?? parent.frame)
        menu.show(menuFrame: frame, parent: parent)
    }

    // MARK: Окно цветов

    func toggleColorMenu() {
        guard let textView else { return }
        if textView.colorMenu.isOpen {
            textView.colorMenu.close()
            return
        }
        guard isShown, let card = cardFrame else { return }
        closeKindMenu()
        textView.colorMenu.open(.selection) { size, visible in FormatBarPlacement.colorMenu(size: size, card: card, visible: visible) }
    }

    func closeKindMenu() {
        kindMenu?.hide()
        kindMenu = nil
    }

    func chooseKind(_ kind: BlockKind) {
        closeKindMenu()
        guard let textView else { return }
        textView.perform(.setKind(kind))
        textView.window?.makeFirstResponder(textView)
        textView.updateFormatBar()
    }

    /// Стрелки, Enter и Esc, пока открыт список типов.
    func handleCommand(_ selector: Selector) -> Bool {
        guard let kindMenu else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): kindMenu.menuView.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): kindMenu.menuView.moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            if case .setKind(let kind)? = kindMenu.menuView.selectedItem?.action { chooseKind(kind) }
        case #selector(NSResponder.cancelOperation(_:)): closeKindMenu()
        default: return false
        }
        return true
    }

    private func makeWindow() -> FormatBarWindow {
        let window = FormatBarWindow()
        window.barView.onButton = { [weak self] button in self?.press(button) }
        window.barView.onKind = { [weak self] in
            guard let self else { return }
            if isKindMenuOpen { closeKindMenu() } else { openKindMenu() }
        }
        self.window = window
        return window
    }

    /// Приложение ушло в фон — панель прячется; прокрутка страницы — панель следует за выделением.
    private func observe() {
        observers.append(PopupWindows.onAppDeactivation { [weak self] in self?.hide() })
        if let clip = textView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.textView?.updateFormatBar() }
            })
        }
    }
}

/// Место карточки панели, как у Notion: под строкой выделения на `selectionSpacing`, левым краем в `pointerOffset`
/// правее `anchorX`; внизу не помещается — над строкой; у края окна прижимается к нему. Координаты экрана.
enum FormatBarPlacement {
    static func card(size: NSSize, line: NSRect, anchorX: CGFloat, visible: NSRect) -> NSRect {
        let spacing = Metrics.FormatBar.selectionSpacing
        var origin = NSPoint(x: anchorX + Metrics.FormatBar.pointerOffset, y: line.minY - spacing - size.height)
        if origin.y < visible.minY { origin.y = line.maxY + spacing }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        return NSRect(origin: origin, size: size)
    }

    /// Список типов, как у Notion: сбоку от карточки — справа, а если там нет места, слева, — заходит на неё
    /// на `kindMenuOverlap` и не закрывает кнопок; серединой против строки типа `row`; в пределах `visible`.
    static func kindMenu(size: NSSize, card: NSRect, row: NSRect, visible: NSRect) -> NSRect {
        let overlap = Metrics.FormatBar.kindMenuOverlap
        // Окно меню встаёт на целые точки: округляем от карточки, чтобы не наехать на кнопку.
        var origin = NSPoint(x: (card.maxX - overlap).rounded(.up), y: row.midY - size.height / 2)
        if origin.x + size.width > visible.maxX { origin.x = (card.minX + overlap).rounded(.down) - size.width }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }
}

extension FormatBarPlacement {
    /// Окно цветов: сбоку от карточки (справа, а если там нет места, слева) с зазором `colorMenuGap`, верхним краем
    /// вровень с карточкой; в пределах `visible`. Координаты экрана.
    static func colorMenu(size: NSSize, card: NSRect, visible: NSRect) -> NSRect {
        let gap = Metrics.FormatBar.colorMenuGap
        var origin = NSPoint(x: (card.maxX + gap).rounded(.up), y: card.maxY - size.height)
        if origin.x + size.width > visible.maxX { origin.x = (card.minX - gap).rounded(.down) - size.width }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        return NSRect(origin: origin, size: size)
    }
}

/// Где поставлена панель для выделения: у первой или последней строки, левым краем у `x` страницы.
/// `x` — в координатах страницы, а не экрана: панель едет вместе с текстом при прокрутке и переносе окна,
/// но не сдвигается, когда жирный или моноширинный текст меняет ширину букв.
struct FormatBarAnchor: Equatable {
    let selection: NSRange
    let atFirstLine: Bool
    let x: CGFloat
}

extension PageTextView {
    // MARK: Панель форматирования

    /// Панель видна, пока в тексте страницы в фокусе выделен текст — внутри блока или через блоки.
    /// Курсор без выделения, режим блоков, набор с подбором букв — панели нет.
    func updateFormatBar() {
        guard !isPerformingCommand else { return }
        let selection = selectedRange()
        guard selection.length > 0, !isBlockSelection, !hasMarkedText(), let window, window.firstResponder === self,
              let blocks = selectedBlockRange() else {
            formatBar.hide()
            return
        }
        let first = firstRect(forCharacterRange: NSRange(location: selection.location, length: 1), actualRange: nil)
        let last = firstRect(forCharacterRange: NSRange(location: NSMaxRange(selection) - 1, length: 1), actualRange: nil)
        let visible = window.convertToScreen(convert(visibleRect, to: nil))
        let anchor = formatBar.anchor.flatMap { $0.selection == selection ? $0 : nil }
            ?? placeFormatBar(for: selection, first: first, last: last, visible: visible, in: window)
        formatBar.anchor = anchor
        let anchorX = window.convertPoint(toScreen: convert(NSPoint(x: anchor.x, y: 0), to: nil)).x
        formatBar.show(formatBarState(for: selection, blocks: blocks), line: anchor.atFirstLine ? first : last,
                       anchorX: anchorX, visible: visible)
    }

    /// Как у Notion: у указателя мыши, если он над страницей (и при выделении клавиатурой), иначе — у конца выделения.
    private func placeFormatBar(for selection: NSRange, first: NSRect, last: NSRect, visible: NSRect, in window: NSWindow) -> FormatBarAnchor {
        let pointer = pointerLocation()
        let atFirstLine = visible.contains(pointer) && abs(pointer.y - first.midY) < abs(pointer.y - last.midY)
        let screenX = visible.contains(pointer) ? pointer.x : last.maxX
        let x = convert(window.convertPoint(fromScreen: NSPoint(x: screenX, y: 0)), from: nil).x
        return FormatBarAnchor(selection: selection, atFirstLine: atFirstLine, x: x)
    }

    /// Тип выделенных блоков и оформление, которое есть у всего выделенного текста.
    func formatBarState(for selection: NSRange, blocks: Range<Int>) -> FormatBarState {
        let pieces = blocks.map { index in (index, localRange(of: selection, inBlockAt: index)) }.filter { !$0.1.isEmpty }
        var active = Set<FormatBarButton>()
        if !pieces.isEmpty {
            for button in FormatBarButton.allCases {
                let covered = pieces.allSatisfy { index, range in
                    let text = document.blocks[index].text
                    if button == .color || button == .equation { return false }
                    guard let format = button.format else { return InlineFormatting.coversLink(text, in: range) }
                    return InlineFormatting.covers(text, with: format, in: range)
                }
                if covered { active.insert(button) }
            }
        }
        let kinds = Set(document.blocks[blocks].map(\.kind).filter { $0 != .pageLink })
        return FormatBarState(kind: kinds.count == 1 ? kinds.first : nil, active: active, lastColor: recentColors.last)
    }
}
