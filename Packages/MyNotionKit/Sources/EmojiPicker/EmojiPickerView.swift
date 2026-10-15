import AppKit
import VisualStyle

/// Карточка окна эмодзи (contracts/visual-style.md, «Окно выбора иконки»): шапка с вкладкой «Эмодзи» и «Убрать»,
/// поле поиска и «Случайная», прокрутка с разделами и сеткой, внизу — строка значков разделов.
@MainActor
final class EmojiPickerView: NSView, NSTextFieldDelegate {
    static let shadowMargin: CGFloat = 32
    static let tabTitle = "Эмодзи"
    static let searchPlaceholder = "Поиск…"

    let searchField = EmojiSearchField()
    let randomButton = EmojiPickerButton(symbolName: "shuffle", label: "Случайная", identifier: "emoji-random")
    let removeButton = EmojiPickerButton(title: "Убрать", identifier: "emoji-remove")
    let grid = EmojiGridView()
    let scrollView = NSScrollView()
    let sectionBar = EmojiSectionBar()
    private let catalog: EmojiCatalog
    private let recents: [String]
    /// Выбран эмодзи; `true` — окно закрывается (у «Случайной» — нет).
    var onChoose: ((String?, Bool) -> Void)?
    var onCancel: (() -> Void)?
    private var isScrollingToSection = false

    init(catalog: EmojiCatalog, recents: [String]) {
        self.catalog = catalog
        self.recents = recents.filter { catalog.emoji($0) != nil }
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.EmojiPicker.width + 2 * Self.shadowMargin,
                                 height: Metrics.EmojiPicker.height + 2 * Self.shadowMargin))
        searchField.delegate = self
        searchField.placeholderString = Self.searchPlaceholder
        addSubview(searchField)
        randomButton.onPress = { [weak self] in self?.chooseRandom() }
        addSubview(randomButton)
        removeButton.onPress = { [weak self] in self?.onChoose?(nil, true) }
        addSubview(removeButton)

        grid.onChoose = { [weak self] in self?.onChoose?($0, true) }
        scrollView.documentView = grid
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        addSubview(scrollView)

        sectionBar.onSelect = { [weak self] in self?.scroll(to: $0) }
        addSubview(sectionBar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Выбор иконки")
        showContent()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var cardRect: NSRect { bounds.insetBy(dx: Self.shadowMargin, dy: Self.shadowMargin) }

    // MARK: Содержимое

    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            if searchField.stringValue != query { searchField.stringValue = query }
            showContent()
        }
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var isSectionBarShown: Bool { !sectionBar.isHidden }
    var shownSections: [EmojiSection] { grid.sections }
    var currentSection: EmojiSection { sectionBar.current }

    private func showContent() {
        if isSearching {
            grid.showResults(catalog.search(query).map(\.character))
        } else {
            var sections: [(EmojiSection, [String])] = []
            if !recents.isEmpty { sections.append((.recent, recents)) }
            for section in EmojiSection.allCases where section != .recent {
                sections.append((section, catalog.emojis(in: section).map(\.character)))
            }
            grid.showSections(sections)
        }
        sectionBar.isHidden = isSearching
        sectionBar.enabled = Set(EmojiSection.allCases.filter { $0 != .recent || !recents.isEmpty })
        sectionBar.current = grid.sections.first ?? .people
        needsLayout = true
        layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scroll(to section: EmojiSection) {
        guard let top = grid.top(of: section) else { return }
        isScrollingToSection = true
        let maxY = max(0, grid.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(top, maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isScrollingToSection = false
        sectionBar.current = section
    }

    @objc private func scrolled() {
        guard !isScrollingToSection, !isSearching else { return }
        if let section = grid.section(atY: scrollView.contentView.bounds.minY + 1) { sectionBar.current = section }
    }

    private func chooseRandom() {
        var generator = SystemRandomNumberGenerator()
        onChoose?(catalog.random(using: &generator).character, false)
    }

    // MARK: Клавиши

    /// Esc — закрыть; Enter — поставить подсвеченный; стрелки — двигать подсветку по сетке.
    func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        case #selector(NSResponder.insertNewline(_:)):
            if let highlighted = grid.highlighted { onChoose?(highlighted, true) }
        case #selector(NSResponder.moveLeft(_:)): moveHighlight(by: -1)
        case #selector(NSResponder.moveRight(_:)): moveHighlight(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveHighlight(by: -Metrics.EmojiPicker.columns)
        case #selector(NSResponder.moveDown(_:)): moveHighlight(by: Metrics.EmojiPicker.columns)
        default: return false
        }
        return true
    }

    private func moveHighlight(by step: Int) {
        grid.moveHighlight(by: step)
        if let highlighted = grid.highlighted, let cell = grid.cellFrame(of: highlighted) {
            grid.scrollToVisible(cell.insetBy(dx: 0, dy: -Metrics.EmojiPicker.cellSize / 2))
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        query = searchField.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handleCommand(selector)
    }

    // MARK: Вид

    private var searchRect: NSRect {
        let metrics = Metrics.EmojiPicker.self
        let card = cardRect
        let right = card.maxX - metrics.rightPadding - metrics.buttonSize - metrics.searchToButtonSpacing
        return NSRect(x: card.minX + metrics.searchLeft, y: card.minY + metrics.searchTop,
                      width: right - card.minX - metrics.searchLeft, height: metrics.searchHeight)
    }

    private var tabTitleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: Typography.popupMenuTitle.fontSize, weight: .medium), .foregroundColor: Palette.textPrimary]
    }

    override func layout() {
        super.layout()
        let metrics = Metrics.EmojiPicker.self
        let card = cardRect
        let search = searchRect
        let fieldHeight = searchField.intrinsicContentSize.height
        searchField.frame = NSRect(x: search.minX + metrics.searchTextX, y: search.midY - fieldHeight / 2,
                                   width: search.width - metrics.searchTextX - metrics.searchIconCenterX / 2, height: fieldHeight)
        randomButton.frame = NSRect(x: card.maxX - metrics.rightPadding - metrics.buttonSize, y: search.midY - metrics.buttonSize / 2,
                                    width: metrics.buttonSize, height: metrics.buttonSize)
        let removeWidth = removeButton.fittingWidth
        removeButton.frame = NSRect(x: card.maxX - metrics.removeRightPadding - removeWidth + metrics.tabUnderlineOutset,
                                    y: card.minY + (metrics.headerHeight - metrics.buttonSize) / 2, width: removeWidth, height: metrics.buttonSize)
        let barHeight = isSectionBarShown ? metrics.sectionBarHeight : 0
        let contentTop = card.minY + metrics.contentTop
        scrollView.frame = NSRect(x: card.minX, y: contentTop, width: card.width, height: card.maxY - barHeight - contentTop)
        grid.frame = NSRect(x: 0, y: 0, width: card.width, height: max(grid.contentHeight, scrollView.contentSize.height))
        sectionBar.frame = NSRect(x: card.minX, y: card.maxY - metrics.sectionBarHeight, width: card.width, height: metrics.sectionBarHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let metrics = Metrics.EmojiPicker.self
        let card = cardRect
        PopupSurface.draw(card: card)

        // Шапка: вкладка «Эмодзи» с чертой цвета текста, под шапкой — разделитель.
        Palette.popupDivider.setFill()
        NSRect(x: card.minX, y: card.minY + metrics.headerHeight - 1, width: card.width, height: 1).fill()
        let tab = NSAttributedString(string: Self.tabTitle, attributes: tabTitleAttributes)
        let tabSize = tab.size()
        tab.draw(at: NSPoint(x: card.minX + metrics.tabTitleX, y: card.minY + (metrics.headerHeight - tabSize.height) / 2))
        Palette.textPrimary.setFill()
        NSRect(x: card.minX + metrics.tabTitleX - metrics.tabUnderlineOutset, y: card.minY + metrics.headerHeight - metrics.tabUnderlineHeight,
               width: tabSize.width + 2 * metrics.tabUnderlineOutset, height: metrics.tabUnderlineHeight).fill()

        // Поле поиска: подложка, синяя рамка (поле в фокусе, пока окно открыто), лупа.
        let search = searchRect
        let field = NSBezierPath(roundedRect: search.insetBy(dx: 0.5, dy: 0.5), xRadius: metrics.searchCornerRadius, yRadius: metrics.searchCornerRadius)
        Palette.emojiSearchBackground.setFill()
        field.fill()
        Palette.focusRing.setStroke()
        field.lineWidth = 1
        field.stroke()
        EmojiPickerSymbol.draw("magnifyingglass", size: metrics.searchIconSize, color: Palette.emojiPickerIcon,
                               center: NSPoint(x: search.minX + metrics.searchIconCenterX, y: search.midY))

        if isSectionBarShown {
            Palette.emojiSectionBarDivider.setFill()
            NSRect(x: card.minX, y: card.maxY - metrics.sectionBarHeight, width: card.width, height: 1).fill()
        }
    }

    /// Карточка в теме `appearance`, вдвое крупнее (для проверок).
    func renderedCard(appearance: NSAppearance) -> NSBitmapImageRep? {
        self.appearance = appearance
        layoutSubtreeIfNeeded()
        let card = cardRect
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(card.width * 2), pixelsHigh: Int(card.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = card.size
        cacheDisplay(in: card, to: rep)
        return rep
    }
}

/// Поле поиска: без своей рамки и фона — их рисует карточка.
@MainActor
final class EmojiSearchField: NSTextField {
    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: Typography.popupMenuTitle.fontSize)
        textColor = Palette.textPrimary
        usesSingleLineMode = true
        cell?.isScrollable = true
        setAccessibilityIdentifier("emoji-search")
        cell?.setAccessibilityIdentifier("emoji-search")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var placeholderString: String? {
        didSet {
            placeholderAttributedString = placeholderString.map {
                NSAttributedString(string: $0, attributes: [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: Palette.textSecondary])
            }
        }
    }
}

/// Системный значок, вписанный в квадрат `size` с серединой в `center`.
@MainActor
enum EmojiPickerSymbol {
    static func draw(_ name: String, size: CGFloat, color: NSColor, center: NSPoint) {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let scale = min(size / symbol.size.width, size / symbol.size.height, 1)
        let drawn = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let tinted = NSImage(size: drawn, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: (center.x - drawn.width / 2).rounded(), y: (center.y - drawn.height / 2).rounded(),
                               width: drawn.width, height: drawn.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Кнопка окна: «Случайная» — значок в квадрате с рамкой, «Убрать» — серая надпись. Под мышью — подложка.
@MainActor
final class EmojiPickerButton: NSView {
    private let symbolName: String?
    private let title: String?
    var onPress: (() -> Void)?
    private var isHovered = false { didSet { needsDisplay = true } }

    init(symbolName: String, label: String, identifier: String) {
        self.symbolName = symbolName
        title = nil
        super.init(frame: .zero)
        configureAccessibility(label: label, identifier: identifier)
    }

    init(title: String, identifier: String) {
        symbolName = nil
        self.title = title
        super.init(frame: .zero)
        configureAccessibility(label: title, identifier: identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private func configureAccessibility(label: String, identifier: String) {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        toolTip = label
    }

    override var isFlipped: Bool { true }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: Typography.popupMenuTitle.fontSize), .foregroundColor: Palette.emojiPickerAction]
    }

    var fittingWidth: CGFloat {
        guard let title else { return Metrics.EmojiPicker.buttonSize }
        return ceil(NSAttributedString(string: title, attributes: titleAttributes).size().width) + 2 * Metrics.EmojiPicker.tabUnderlineOutset
    }

    func press() { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }

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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Metrics.EmojiPicker.buttonCornerRadius
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if isHovered {
            Palette.hoverBackground.setFill()
            shape.fill()
        }
        if let symbolName {
            Palette.emojiButtonBorder.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            EmojiPickerSymbol.draw(symbolName, size: Metrics.EmojiPicker.buttonIconSize, color: Palette.emojiPickerIcon,
                                   center: NSPoint(x: bounds.midX, y: bounds.midY))
        } else if let title {
            let text = NSAttributedString(string: title, attributes: titleAttributes)
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
    }
}
