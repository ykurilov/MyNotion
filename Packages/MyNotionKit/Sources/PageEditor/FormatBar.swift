import AppKit
import NotesCore
import VisualStyle

/// Кнопка панели форматирования (FR-033), как у Notion 7.39: два ряда по 5, слева направо и сверху вниз.
public enum FormatBarButton: String, CaseIterable, Sendable {
    case color
    case bold
    case italic
    case underline
    /// «Tx» — снять оформление и цвета.
    case clearFormatting
    case link
    case strikethrough
    case code
    /// «√x» — формула в строке (US4).
    case equation
    /// «⋯» — меню блока.
    case more

    var title: String {
        switch self {
        case .color: "Цвет"
        case .bold: "Жирный"
        case .italic: "Курсив"
        case .underline: "Подчёркнутый"
        case .clearFormatting: "Убрать оформление"
        case .link: "Ссылка"
        case .strikethrough: "Зачёркнутый"
        case .code: "Код"
        case .equation: "Формула"
        case .more: "Ещё"
        }
    }

    var symbolName: String? {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .equation: "x.squareroot"
        case .link: "link"
        case .more: "ellipsis"
        case .color, .clearFormatting: nil
        }
    }

    /// Оформление кнопки; у остальных — своё действие.
    var format: InlineFormat? {
        switch self {
        case .bold: .bold
        case .italic: .italic
        case .underline: .underline
        case .strikethrough: .strikethrough
        case .code: .code
        case .color, .clearFormatting, .link, .equation, .more: nil
        }
    }
}

/// Что показывает панель: тип выделенных блоков (`nil` — разные), нажатые кнопки и текущие цвета выделения.
struct FormatBarState: Equatable {
    var kind: BlockKind?
    var active: Set<FormatBarButton>
    /// Цвет текста и фона всего выделения (если он один): «A» — буквой цвета текста на фоне цвета фона.
    var currentColors: Set<ColorChoice> = []

    var kindItem: PopupMenuItem? {
        kind.flatMap { kind in PopupMenuItem.blockKinds.first { $0.action == .setKind(kind) } }
    }

    /// Как «Multiple Types» у Notion, когда выделены блоки разных типов.
    var kindTitle: String { kindItem?.title ?? "Разные типы" }
    var kindIcon: PopupMenuItem.Icon { kindItem?.icon ?? .symbol("square.stack") }

    func currentColor(_ target: ColorTarget) -> NotionColor? {
        currentColors.first { $0.target == target }?.color
    }
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

/// Карточка панели: строка типа блока со стрелкой «›» и под ней два ряда кнопок, как у Notion 7.39
/// (contracts/visual-style.md, «Панель форматирования»).
@MainActor
final class FormatBarView: NSView {
    let kindRow = FormatBarKindRowView()
    /// «Исправить ошибки» под кнопками.
    let proofreadRow = FormatBarActionRowView(title: "Исправить ошибки", symbolName: "text.badge.checkmark", identifier: "format-proofread")
    private(set) var buttons: [FormatBarButtonView] = []
    var state = FormatBarState(kind: .paragraph, active: []) {
        didSet {
            guard state != oldValue else { return }
            kindRow.state = state
            for button in buttons {
                button.isActive = state.active.contains(button.button)
                button.currentColors = state.currentColors
            }
        }
    }
    var onKind: (() -> Void)? {
        get { kindRow.onClick }
        set { kindRow.onClick = newValue }
    }
    var onButton: ((FormatBarButton) -> Void)?
    var onProofread: (() -> Void)? {
        get { proofreadRow.onClick }
        set { proofreadRow.onClick = newValue }
    }

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
        addSubview(proofreadRow)
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
        let rowTop = kindRow.frame.maxY + Metrics.FormatBar.kindToButtonsSpacing
        let columns = Metrics.FormatBar.buttonColumns
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: card.minX + Metrics.FormatBar.horizontalPadding + CGFloat(index % columns) * Metrics.FormatBar.buttonWidth,
                                  y: rowTop + CGFloat(index / columns) * Metrics.FormatBar.buttonRowHeight,
                                  width: Metrics.FormatBar.buttonWidth, height: Metrics.FormatBar.buttonRowHeight)
        }
        proofreadRow.frame = NSRect(x: kindRow.frame.minX, y: actionDividerY + Metrics.FormatBar.actionDividerSpacing / 2,
                                    width: kindRow.frame.width, height: Metrics.FormatBar.actionRowHeight)
    }

    /// Линия между кнопками и строкой «Исправить ошибки».
    private var actionDividerY: CGFloat {
        card.minY + Metrics.FormatBar.verticalPadding + Metrics.FormatBar.kindRowHeight + Metrics.FormatBar.kindToButtonsSpacing
            + CGFloat(Metrics.FormatBar.buttonRows) * Metrics.FormatBar.buttonRowHeight + Metrics.FormatBar.actionDividerSpacing / 2
    }

    func buttonView(_ button: FormatBarButton) -> FormatBarButtonView? {
        buttons.first { $0.button == button }
    }

    override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: card)
        Palette.popupDivider.setFill()
        NSRect(x: card.minX, y: actionDividerY.rounded(.down), width: card.width, height: 1).fill()
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

/// Строка действия под кнопками: значок на месте значка типа, название — с той же линии, что название типа.
@MainActor
final class FormatBarActionRowView: FormatBarControlView {
    let title: String
    private let symbolName: String

    init(title: String, symbolName: String, identifier: String) {
        self.title = title
        self.symbolName = symbolName
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered { PopupMenuRowView.drawHighlight(in: bounds) }
        let inset = Metrics.PopupMenu.rowInset
        let iconSize = Metrics.PopupMenu.iconSize
        PopupMenuRowView.drawIcon(.symbol(symbolName), color: Palette.textPrimary,
                                  in: NSRect(x: Metrics.FormatBar.kindIconCenterX - inset - iconSize / 2, y: (bounds.height - iconSize) / 2,
                                             width: iconSize, height: iconSize))
        let titleStyle = Typography.popupMenuTitle
        let textX = Metrics.FormatBar.kindTitleX - inset
        NSAttributedString(string: title, attributes: [.font: titleStyle.font, .foregroundColor: Palette.textPrimary])
            .draw(in: NSRect(x: textX, y: (bounds.height - titleStyle.lineHeight) / 2, width: bounds.maxX - textX, height: titleStyle.lineHeight))
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
    /// Текущие цвета выделения: «A» — буквой цвета текста на фоне цвета фона.
    var currentColors: Set<ColorChoice> = [] { didSet { if currentColors != oldValue, button == .color { needsDisplay = true } } }
    /// Открыто ли окно цветов: кнопка «A» подсвечена, как под мышью.
    var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private let symbol: NSImage?
    /// Где в картинке значка сам рисунок: значок ставится по центру рисунка, а не картинки.
    private let ink: NSRect

    init(button: FormatBarButton) {
        self.button = button
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.FormatBar.buttonGlyphSize, weight: .regular)
        symbol = button.symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: button.title)?.withSymbolConfiguration(configuration) }
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
        if isHovered || isPressed {
            let size = Metrics.FormatBar.buttonHighlightSize
            let radius = Metrics.FormatBar.buttonCornerRadius
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height),
                         xRadius: radius, yRadius: radius).fill()
        }
        switch button {
        case .color: return drawColorGlyph()
        case .clearFormatting: return drawClearFormattingGlyph()
        default: break
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
    /// Кнопка цвета, как у Notion 7.39: «A» в рамке 20 по центру места; буква — цвета текста выделения,
    /// рамка залита цветом фона выделения.
    fileprivate func drawColorGlyph() {
        let side = Metrics.FormatBar.colorButtonBoxSize
        let radius = Metrics.FormatBar.colorButtonBoxCornerRadius
        let box = NSRect(x: (bounds.midX - side / 2).rounded(), y: (bounds.midY - side / 2).rounded(), width: side, height: side)
        let shape = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let textTone = currentColors.first { $0.target == .text }?.color?.tone
        let backgroundTone = currentColors.first { $0.target == .background }?.color?.tone
        if let fill = Palette.notionBackground(backgroundTone) {
            fill.setFill()
            shape.fill()
        }
        Palette.popupDivider.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let font = NSFont.systemFont(ofSize: Metrics.FormatBar.colorButtonGlyphSize, weight: .medium)
        let glyph = NSAttributedString(string: "A", attributes: [.font: font, .foregroundColor: Palette.notionText(textTone)])
        let size = glyph.size()
        glyph.draw(at: NSPoint(x: (box.midX - size.width / 2).rounded(), y: (box.midY - size.height / 2).rounded()))
    }

    /// «Tx»: «T» шрифтом значков и «x» мельче, справа внизу, как у Notion.
    fileprivate func drawClearFormattingGlyph() {
        let color = Palette.textPrimary
        let letter = NSAttributedString(string: "T", attributes: [
            .font: NSFont.systemFont(ofSize: Metrics.FormatBar.buttonGlyphSize, weight: .regular), .foregroundColor: color,
        ])
        let index = NSAttributedString(string: "x", attributes: [
            .font: NSFont.systemFont(ofSize: Metrics.FormatBar.clearFormattingSubscriptSize, weight: .regular), .foregroundColor: color,
        ])
        let letterSize = letter.size(), indexSize = index.size()
        let x = (bounds.midX - (letterSize.width + indexSize.width) / 2).rounded()
        let y = (bounds.midY - letterSize.height / 2).rounded()
        letter.draw(at: NSPoint(x: x, y: y))
        index.draw(at: NSPoint(x: x + letterSize.width - 1, y: y + letterSize.height - indexSize.height))
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
    /// Подписка снимается в `deinit` — он не привязан к главному потоку.
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

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

    /// «Исправить ошибки»: панель уступает место окну правок.
    func proofread() {
        guard isShown, let textView else { return }
        hide()
        textView.startProofreading()
    }

    func press(_ button: FormatBarButton) {
        guard isShown, let textView else { return }
        guard button != .color else {
            toggleColorMenu()
            return
        }
        closeKindMenu()
        textView.colorMenu.close()
        switch button {
        case .equation:
            hide()
            textView.perform(.insertInlineEquation)
            return
        case .clearFormatting:
            textView.perform(.clearInlineFormatting)
            textView.updateFormatBar()
            return
        case .more:
            openBlockMenu()
            return
        default: break
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
        // Список длиннее экрана — по высоте видимой области, с прокруткой; текущий тип виден сразу.
        let visible = parent.screen.map { $0.visibleFrame.intersection(parent.frame) } ?? parent.frame
        menu.menuView.maximumHeight = visible.height
        if let current = state.kindItem { menu.menuView.select(current) }
        let frame = FormatBarPlacement.kindMenu(size: menu.menuView.fittingMenuSize, card: card, row: rowOnScreen, visible: visible)
        menu.show(menuFrame: frame, parent: parent)
    }

    // MARK: Окно цветов

    func toggleColorMenu() {
        guard let textView else { return }
        if textView.colorMenu.isOpen {
            textView.colorMenu.close()
            return
        }
        guard isShown, let button = buttonFrame(.color) else { return }
        closeKindMenu()
        textView.colorMenu.open(.selection) { size, visible in FormatBarPlacement.colorMenu(size: size, button: button, visible: visible) }
        window?.barView.buttonView(.color)?.isPressed = textView.colorMenu.isOpen
    }

    /// Окно цветов закрылось: кнопка «A» больше не подсвечена.
    func colorMenuDidClose() {
        window?.barView.buttonView(.color)?.isPressed = false
    }

    /// Место кнопки на экране.
    func buttonFrame(_ button: FormatBarButton) -> NSRect? {
        guard let window, let view = window.barView.buttonView(button) else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// «⋯»: меню блока, в котором начинается выделение, под кнопкой, как у Notion; панель прячется.
    private func openBlockMenu() {
        guard let textView, let index = textView.selectedBlockRange()?.lowerBound else { return }
        let anchor = buttonFrame(.more) ?? .zero
        let id = textView.document.blocks[index].id
        hide()
        textView.openBlockMenu(forBlock: id, below: anchor)
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
        window.barView.onProofread = { [weak self] in self?.proofread() }
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
    /// Окно цветов, как у Notion 7.39: под местом кнопки «A» `button` с зазором `colorMenuGap`, левым краем вровень
    /// с ним, поверх панели; внизу нет места — над кнопкой; в пределах `visible`. Координаты экрана.
    static func colorMenu(size: NSSize, button: NSRect, visible: NSRect) -> NSRect {
        let gap = Metrics.FormatBar.colorMenuGap
        var origin = NSPoint(x: button.minX, y: button.minY - gap - size.height)
        if origin.y < visible.minY { origin.y = button.maxY + gap }
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
        // Пока открыто окно правок, панели нет: окно стоит на её месте.
        guard !proofreading.isShown else {
            formatBar.hide()
            return
        }
        let selection = selectedRange()
        guard selection.length > 0, !isBlockSelection, !hasMarkedText(), let window, window.firstResponder === self,
              let blocks = selectedBlockRange() else {
            formatBar.hide()
            return
        }
        let first = firstRect(forCharacterRange: NSRange(location: selection.location, length: 1), actualRange: nil)
        let last = firstRect(forCharacterRange: NSRange(location: NSMaxRange(selection) - 1, length: 1), actualRange: nil)
        let visible = window.convertToScreen(convert(visibleRect, to: nil))
        // Окно цветов красит то выделение, ради которого открыто: новое выделение его закрывает.
        if formatBar.anchor?.selection != selection, colorMenu.target == .selection { colorMenu.close() }
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
            for button in FormatBarButton.allCases where button.format != nil || button == .link {
                let covered = pieces.allSatisfy { index, range in
                    let text = document.blocks[index].text
                    guard let format = button.format else { return InlineFormatting.coversLink(text, in: range) }
                    return InlineFormatting.covers(text, with: format, in: range)
                }
                if covered { active.insert(button) }
            }
        }
        let kinds = Set(document.blocks[blocks].map(\.kind).filter { $0 != .pageLink })
        return FormatBarState(kind: kinds.count == 1 ? kinds.first : nil, active: active, currentColors: currentColors(for: .selection))
    }
}
