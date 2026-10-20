import AppKit
import NotesCore
import VisualStyle

/// Боковое дерево страниц: системный `NSOutlineView` (клавиши, перетаскивание, доступность)
/// со своими строками по contracts/visual-style.md, «Боковая панель».
/// Enter — переименовать, ⌘⌫ — в корзину, ← / → — свернуть и развернуть ветку.
final class PageOutlineView: NSOutlineView {
    var onRename: ((_ row: Int) -> Void)?
    var onTrash: ((_ row: Int) -> Void)?
    var onContextMenu: ((_ row: Int) -> NSMenu?)?
    /// Подписка снимается в `deinit` — он не привязан к главному потоку.
    nonisolated(unsafe) private var clipObserver: (any NSObjectProtocol)?

    deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    /// Раздел панели («Избранное», «Недавние») тянет за собой свои идентификаторы доступности: тесты находят его отдельно от дерева.
    func useSectionIdentifier(_ name: String, label: String) {
        setAccessibilityIdentifier("\(name)-tree")
        setAccessibilityLabel(label)
    }

    /// Видимая часть списка сменила высоту (внизу панели появилась строка): выбранная строка, срезанная краем,
    /// докручивается целиком — иначе её подсветка торчит полоской над разделителем. Скрытую целиком не трогаем:
    /// список прокрутили сами.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        clipObserver = nil
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip,
                                                              queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepSelectedRowWhole() }
        }
    }

    private func keepSelectedRowWhole() {
        guard selectedRow >= 0 else { return }
        let row = rect(ofRow: selectedRow), visible = visibleRect
        if row.intersects(visible), !visible.contains(row) { scrollRowToVisible(selectedRow) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        outlineTableColumn = column
        headerView = nil
        style = .plain
        backgroundColor = .clear
        rowHeight = Metrics.Sidebar.rowPitch
        intercellSpacing = .zero
        indentationPerLevel = Metrics.Sidebar.indentPerLevel
        // Колонка — ровно по панели: иначе раскрытие ветки расширяет её на отступ, и «⋯ +» уезжают за край.
        autoresizesOutlineColumn = false
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        focusRingType = .none
        selectionHighlightStyle = .regular
        draggingDestinationFeedbackStyle = .regular
        setDraggingSourceOperationMask(.move, forLocal: true)
        setAccessibilityIdentifier("page-tree")
        setAccessibilityLabel("Страницы")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    /// Системного треугольника нет: стрелка — в строке вместо иконки, при наведении.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    /// Вложенность — только сдвиг на `indentPerLevel` за уровень, без места под треугольник.
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        let leading = CGFloat(level(forRow: row)) * indentationPerLevel
        return NSRect(x: leading, y: frame.minY, width: max(0, bounds.width - leading), height: frame.height)
    }

    /// Меню по правой кнопке — то же, что у «⋯».
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? onContextMenu?(row) : nil
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isDelete = event.keyCode == 51
        if selectedRow >= 0, isReturn, flags.isEmpty {
            onRename?(selectedRow)
        } else if selectedRow >= 0, isDelete, flags == .command {
            onTrash?(selectedRow)
        } else {
            super.keyDown(with: event)
        }
    }
}

extension NSPasteboard.PasteboardType {
    /// id страницы, которую тянут в дереве.
    static let myNotionPageId = NSPasteboard.PasteboardType("cloud.kurilov.mynotion.page-id")
    /// id избранной страницы, которую тянут в разделе «Избранное».
    static let myNotionFavoritePageId = NSPasteboard.PasteboardType("cloud.kurilov.mynotion.favorite-page-id")
}

// MARK: Строка

/// Фон строки: выбранная или под мышью — скруглённый прямоугольник цвета hoverBackground.
final class PageTreeRowView: NSTableRowView {
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            cellView?.isRowHovered = isHovered
        }
    }

    private var cellView: PageTreeCellView? {
        subviews.lazy.compactMap { $0 as? PageTreeCellView }.first
    }

    override var isSelected: Bool {
        didSet { cellView?.isRowSelected = isSelected }
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard isHovered, !isSelected else { return }
        drawRoundedFill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        drawRoundedFill()
    }

    /// Подсветка высотой `rowHeight` посередине шага строк: между соседними подсветками зазор, как у Notion.
    var highlightRect: NSRect {
        bounds.insetBy(dx: 0, dy: (bounds.height - Metrics.Sidebar.rowHeight) / 2)
    }

    private func drawRoundedFill() {
        Palette.hoverBackground.setFill()
        let radius = Metrics.Sidebar.rowCornerRadius
        NSBezierPath(roundedRect: highlightRect, xRadius: radius, yRadius: radius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
        if let window {
            isHovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

// MARK: Содержимое строки

/// Иконка (эмодзи или значок документа), название и при наведении: стрелка вместо иконки, «⋯» и «+» справа.
final class PageTreeCellView: NSTableCellView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("page-tree-row")

    /// Начало идентификаторов доступности частей строки: у дерева «page-tree», у разделов — свои.
    let idPrefix: String
    var onToggleExpanded: (() -> Void)?
    var onAddSubpage: (() -> Void)?
    var onChooseIcon: ((NSView) -> Void)?
    var onShowMenu: ((NSView) -> Void)?
    var onRenameCommitted: ((String) -> Void)?

    private let iconLabel = NSTextField(labelWithString: "")
    let documentIcon = NSImageView()
    /// Прозрачная кнопка поверх иконки: щелчок открывает окно выбора иконки.
    let iconButton = NSButton()
    let titleLabel = NSTextField(labelWithString: "")
    /// Стрелка, «⋯» и «+» нужны только строке под мышью, поле переименования — только при переименовании:
    /// они создаются по требованию. Так строка дешевле, и дерево быстрее показывает новые строки при прокрутке
    /// (переход к странице далеко в дереве, принцип II).
    private(set) lazy var disclosureButton = makeDisclosureButton()
    private(set) lazy var menuButton = makeAccessories().menu
    private(set) lazy var addButton = makeAccessories().add
    private var accessories: (menu: RowAccessoryButton, add: RowAccessoryButton)?
    private var hasDisclosureButton = false
    /// Поле переименования: стоит ровно на месте названия, текст не сдвигается; длинное прокручивается.
    private(set) lazy var renameField = makeRenameField()
    private var hasRenameField = false
    private var title = ""
    private var hasChildren = false
    private var isExpanded = false
    private var isRenaming = false
    private var renameCancelled = false
    /// Пока видны «⋯» и «+», название кончается перед ними.
    private var titleBeforeAccessories: NSLayoutConstraint?

    var isRowHovered = false { didSet { updateHoverState() } }
    var isRowSelected = false { didSet { updateTitleColor() } }

    init(frame frameRect: NSRect, idPrefix: String = "page-tree") {
        self.idPrefix = idPrefix
        super.init(frame: frameRect)
        identifier = Self.identifier
        textField = titleLabel

        iconLabel.font = .systemFont(ofSize: Metrics.Sidebar.rowEmojiFontSize)
        iconLabel.alignment = .center
        documentIcon.image = DocumentGlyph.image(size: Metrics.Sidebar.rowIconSize)
        documentIcon.imageScaling = .scaleNone
        iconButton.isBordered = false
        iconButton.title = ""
        iconButton.target = self
        iconButton.action = #selector(chooseIcon)
        iconButton.setAccessibilityLabel("Сменить иконку")
        iconButton.setAccessibilityIdentifier("\(idPrefix)-icon")

        titleLabel.font = Typography.sidebarRow.font
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setAccessibilityIdentifier("\(idPrefix)-title")

        for view in [iconLabel, documentIcon, iconButton, titleLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let iconSize = Metrics.Sidebar.rowIconSize
        let padding = Metrics.Sidebar.rowHorizontalPadding
        NSLayoutConstraint.activate([
            // Эмодзи — по центру квадрата иконки, как значок документа: ширина эмодзи своя.
            documentIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            iconLabel.centerXAnchor.constraint(equalTo: documentIcon.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            documentIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            documentIcon.widthAnchor.constraint(equalToConstant: iconSize),
            documentIcon.heightAnchor.constraint(equalToConstant: iconSize),
            iconButton.leadingAnchor.constraint(equalTo: documentIcon.leadingAnchor),
            iconButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconButton.widthAnchor.constraint(equalToConstant: iconSize),
            iconButton.heightAnchor.constraint(equalToConstant: iconSize),

            titleLabel.leadingAnchor.constraint(equalTo: documentIcon.trailingAnchor, constant: Metrics.Sidebar.rowIconSpacing),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padding),
        ])
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateHoverState()
    }

    // MARK: Части по требованию

    private func makeDisclosureButton() -> RowAccessoryButton {
        let button = RowAccessoryButton()
        configureIconButton(button, symbol: "chevron.right", label: "Свернуть или развернуть",
                            pointSize: Metrics.Sidebar.disclosureSymbolSize, action: #selector(toggleExpanded), tint: Palette.handleIcon)
        button.setAccessibilityIdentifier("\(idPrefix)-disclosure")
        add(button)
        let iconSize = Metrics.Sidebar.rowIconSize
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: documentIcon.leadingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: iconSize),
            button.heightAnchor.constraint(equalToConstant: iconSize),
        ])
        hasDisclosureButton = true
        return button
    }

    private func makeAccessories() -> (menu: RowAccessoryButton, add: RowAccessoryButton) {
        if let accessories { return accessories }
        let menu = RowAccessoryButton(), add = RowAccessoryButton()
        configureIconButton(menu, symbol: "ellipsis", label: "Действия со страницей",
                            pointSize: Metrics.Sidebar.accessorySymbolSize, action: #selector(showMenu))
        menu.setAccessibilityIdentifier("\(idPrefix)-menu")
        configureIconButton(add, symbol: "plus", label: "Добавить подстраницу",
                            pointSize: Metrics.Sidebar.accessorySymbolSize, action: #selector(addSubpage))
        add.setAccessibilityIdentifier("\(idPrefix)-add-subpage")
        self.add(menu)
        self.add(add)
        let size = Metrics.Sidebar.rowAccessorySize
        NSLayoutConstraint.activate([
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.Sidebar.rowHorizontalPadding),
            add.centerYAnchor.constraint(equalTo: centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: size),
            add.heightAnchor.constraint(equalToConstant: size),
            menu.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -Metrics.Sidebar.rowAccessorySpacing),
            menu.centerYAnchor.constraint(equalTo: centerYAnchor),
            menu.widthAnchor.constraint(equalToConstant: size),
            menu.heightAnchor.constraint(equalToConstant: size),
        ])
        titleBeforeAccessories = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: menu.leadingAnchor,
                                                                      constant: -Metrics.Sidebar.rowAccessorySpacing)
        accessories = (menu, add)
        return (menu, add)
    }

    private func makeRenameField() -> RenameField {
        let field = RenameField()
        field.font = Typography.sidebarRow.font
        field.textColor = Palette.textPrimary
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.delegate = self
        field.isHidden = true
        field.setAccessibilityIdentifier("\(idPrefix)-rename")
        add(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: Self.renameTextOffset),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.Sidebar.rowHorizontalPadding + Self.renameTextOffset),
            field.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
        hasRenameField = true
        return field
    }

    private func add(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func show(_ page: Page, title: String, hasChildren: Bool, isExpanded: Bool) {
        if !isRenaming {
            self.title = title
            titleLabel.stringValue = title
        }
        self.hasChildren = hasChildren
        self.isExpanded = isExpanded
        iconLabel.stringValue = page.icon ?? ""
        documentIcon.isHidden = page.icon != nil
        setAccessibilityLabel(title)
        updateHoverState()
        updateTitleColor()
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        updateHoverState()
    }

    // MARK: Переименование

    /// Текст редактируемого поля стоит на 2 правее его рамки и выходит на 2 за правый край (замер в SidebarGeometryTests):
    /// поле шире на 2 с каждой стороны, чтобы текст встал ровно на место названия и кончался за 8 до края строки.
    static let renameTextOffset: CGFloat = -2

    func beginRenaming() {
        guard let window else { return }
        isRenaming = true
        renameCancelled = false
        renameField.stringValue = title
        renameField.isHidden = false
        titleLabel.isHidden = true
        updateHoverState()
        window.makeFirstResponder(renameField)
        // Общий редактор окна рисует белый фон и рамку фокуса: поле стоит на строке без плашки.
        if let editor = renameField.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.focusRingType = .none
            editor.enclosingScrollView?.drawsBackground = false
        }
        renameField.currentEditor()?.selectAll(nil)
    }

    private func finishRenaming() {
        isRenaming = false
        if hasRenameField { renameField.isHidden = true }
        titleLabel.isHidden = false
        updateHoverState()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        renameCancelled = true
        renameField.stringValue = title
        window?.makeFirstResponder(enclosingOutline)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isRenaming else { return }
        finishRenaming()
        let newTitle = renameField.stringValue
        if !renameCancelled, newTitle != title {
            title = newTitle
            titleLabel.stringValue = newTitle
            onRenameCommitted?(newTitle)
        }
        if window?.firstResponder == nil || window?.firstResponder === window {
            window?.makeFirstResponder(enclosingOutline)
        }
    }

    private var enclosingOutline: NSOutlineView? {
        var view = superview
        while let current = view, !(current is NSOutlineView) { view = current.superview }
        return view as? NSOutlineView
    }

    // MARK: Вид

    /// «⋯» и «+» — одного размера и веса, цвета второстепенного текста; стрелка раскрытия — цвета ручек.
    private func configureIconButton(_ button: NSButton, symbol: String, label: String, pointSize: CGFloat, action: Selector,
                                     tint: NSColor = Palette.textSecondary) {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        button.contentTintColor = tint
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    private func updateHoverState() {
        let showsDisclosure = isRowHovered && hasChildren && !isRenaming
        if showsDisclosure || hasDisclosureButton {
            disclosureButton.isHidden = !showsDisclosure
            disclosureButton.frameCenterRotation = 0
            disclosureButton.image = isExpanded ? Self.chevronDown : Self.chevronRight
        }
        iconLabel.alphaValue = showsDisclosure ? 0 : 1
        documentIcon.alphaValue = showsDisclosure ? 0 : 1
        iconButton.isHidden = showsDisclosure
        let showsAccessories = isRowHovered && !isRenaming
        if showsAccessories || accessories != nil {
            menuButton.isHidden = !showsAccessories
            addButton.isHidden = !showsAccessories
            titleBeforeAccessories?.isActive = showsAccessories
        }
    }

    private static func chevron(_ symbol: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: Metrics.Sidebar.disclosureSymbolSize, weight: .semibold)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: "Свернуть или развернуть")?.withSymbolConfiguration(configuration)
    }
    private static let chevronRight = chevron("chevron.right")
    private static let chevronDown = chevron("chevron.down")

    private func updateTitleColor() {
        titleLabel.textColor = isRowSelected ? Palette.textPrimary : Palette.sidebarText
    }

    @objc private func toggleExpanded() { onToggleExpanded?() }
    @objc private func addSubpage() { onAddSubpage?() }
    @objc private func chooseIcon() { onChooseIcon?(iconButton) }
    @objc private func showMenu() { onShowMenu?(menuButton) }
}

/// Кнопка строки («⋯», «+», стрелка): под мышью — фон hoverBackground со скруглением, как в Notion.
final class RowAccessoryButton: NSButton {
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override var isHidden: Bool {
        didSet { if isHidden { isHovered = false } }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Palette.hoverBackground.setFill()
            let radius = Metrics.Sidebar.rowAccessoryCornerRadius
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        super.draw(dirtyRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// Поле переименования: рамка поля — ровно то место, где виден текст (у обычного поля текст выходит на 2 за рамку выравнивания).
final class RenameField: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}
