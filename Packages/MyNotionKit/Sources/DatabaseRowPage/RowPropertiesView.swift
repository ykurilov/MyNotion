import AppKit
import DatabaseGrid
import Databases
import NotesCore
import VisualStyle

/// Свойства строки под названием (contracts/database-ui.md, «Страница строки»): строка на свойство — слева значок
/// типа и имя серым, справа значение (пустое — «Пусто»); внизу «+ Добавить свойство». Правка — по `RowPropertyEditing`:
/// поле на месте, щелчок по флажку; окна выбора, даты, файлов и связи открывает хозяин (`onOpenEditor`).
@MainActor
public final class RowPropertiesView: NSView {
    /// Записать значение свойства (`nil` — стереть).
    public var onCommit: ((UUID, JSONValue?) -> Void)?
    /// «+ Добавить свойство»: окно типов под кнопкой.
    public var onAddProperty: ((NSView) -> Void)?
    /// Щелчок по значению с окном правки (выбор, статус, дата, файлы, связь — US2, US4).
    public var onOpenEditor: ((UUID, NSView) -> Void)?
    /// Высота сменилась (свойство добавили или удалили): хозяин переставляет место «под названием».
    public var onHeightChange: ((CGFloat) -> Void)?

    public private(set) var page: RowPage
    private var lineViews: [RowPropertyLineView] = []
    private let addButton = RowAddPropertyButton()
    /// Пока значение правится, новое чтение ждёт: поле не пересоздаётся под пальцами.
    private var pendingPage: RowPage?

    public init(page: RowPage) {
        self.page = page
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Свойства")
        setAccessibilityIdentifier("row-properties")
        addButton.onPress = { [weak self] in
            guard let self else { return }
            onAddProperty?(addButton)
        }
        addSubview(addButton)
        rebuildLines()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    public var fittingHeight: CGFloat { Self.height(lineCount: lineViews.count) }

    static func height(lineCount: Int) -> CGFloat {
        let metrics = Metrics.RowPage.self
        return metrics.topPadding + CGFloat(lineCount + 1) * metrics.lineHeight + metrics.bottomPadding
    }

    /// Новые значения или схема: строки пересобираются, правка в поле — после неё.
    public func show(_ page: RowPage) {
        guard !lineViews.contains(where: \.isEditing) else {
            pendingPage = page
            return
        }
        let oldHeight = fittingHeight
        self.page = page
        rebuildLines()
        if fittingHeight != oldHeight { onHeightChange?(fittingHeight) }
    }

    /// Строки свойств видом; у тех же свойств виды остаются (меняется только значение).
    private func rebuildLines() {
        let old = Dictionary(uniqueKeysWithValues: lineViews.map { ($0.line.propertyId, $0) })
        var views: [RowPropertyLineView] = []
        for line in page.lines {
            let view = old[line.propertyId] ?? RowPropertyLineView(line: line)
            view.show(line)
            view.onAction = { [weak self, weak view] action in
                guard let self, let view else { return }
                perform(action, in: view)
            }
            if view.superview !== self { addSubview(view) }
            views.append(view)
        }
        for view in lineViews where !views.contains(where: { $0 === view }) { view.removeFromSuperview() }
        lineViews = views
        needsLayout = true
    }

    private func perform(_ action: RowPropertyLineView.Action, in view: RowPropertyLineView) {
        let propertyId = view.line.propertyId
        switch action {
        case .beginEditing: view.beginEditing(text: page.editText(of: propertyId))
        case .endEditing(let text, let changed):
            if changed { onCommit?(propertyId, page.value(fromText: text, for: propertyId)) }
            if let pendingPage {
                self.pendingPage = nil
                show(pendingPage)
            }
        case .toggle: onCommit?(propertyId, page.toggledValue(of: propertyId))
        case .openEditor: onOpenEditor?(propertyId, view.valueAnchor)
        }
    }

    public override func layout() {
        super.layout()
        let metrics = Metrics.RowPage.self
        var y = metrics.topPadding
        for view in lineViews {
            view.frame = NSRect(x: 0, y: y, width: bounds.width, height: metrics.lineHeight)
            y += metrics.lineHeight
        }
        addButton.frame = NSRect(x: 0, y: y, width: min(bounds.width, addButton.fittingWidth), height: metrics.lineHeight)
    }

    /// Строка свойства (для проб и UI-тестов).
    func lineView(for propertyId: UUID) -> RowPropertyLineView? { lineViews.first { $0.line.propertyId == propertyId } }
}

/// Строка свойства: значок и имя серым, справа значение; под мышью — подложка у значения, которое правится.
@MainActor
final class RowPropertyLineView: NSView, NSTextFieldDelegate {
    enum Action {
        case beginEditing
        case endEditing(text: String, changed: Bool)
        case toggle
        case openEditor
    }

    private(set) var line: RowPropertyLine
    var onAction: ((Action) -> Void)?
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private var chipViews: [OptionChip] = []
    private let checkbox = RowCheckboxView()
    private var editor: NSTextField?
    private var editStartText = ""
    private var isValueHovered = false { didSet { if isValueHovered != oldValue { needsDisplay = true } } }

    var isEditing: Bool { editor != nil }

    init(line: RowPropertyLine) {
        self.line = line
        super.init(frame: .zero)
        let font = NSFont.systemFont(ofSize: Metrics.RowPage.fontSize)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = Palette.textSecondary
        nameLabel.font = font
        nameLabel.textColor = Palette.textSecondary
        nameLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = font
        valueLabel.lineBreakMode = .byTruncatingTail
        for view in [icon, nameLabel, valueLabel, checkbox] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("row-property")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var isEditable: Bool { line.editing != .readOnly }

    func show(_ line: RowPropertyLine) {
        self.line = line
        icon.image = NSImage(systemSymbolName: line.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Metrics.RowPage.iconSize - 2, weight: .regular))
        nameLabel.stringValue = line.name
        setAccessibilityLabel(line.name)
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = []
        valueLabel.isHidden = true
        checkbox.isHidden = true
        switch line.presentation {
        case .empty:
            valueLabel.stringValue = RowPropertyLine.emptyText
            // «Пусто» — бледно-серым, как подписи кнопок шапки (у Notion «Empty» бледнее имени).
            valueLabel.textColor = Palette.pageHeaderButton
            valueLabel.isHidden = false
        case .text(let text):
            valueLabel.stringValue = text
            valueLabel.textColor = Palette.textPrimary
            valueLabel.isHidden = false
        case .checkbox(let checked):
            checkbox.isChecked = checked
            checkbox.isHidden = false
        case .chips(let chips):
            chipViews = chips.map { OptionChip(title: $0.title, color: $0.color) }
            chipViews.forEach(addSubview)
        }
        setAccessibilityValue(line.presentation == .empty ? RowPropertyLine.emptyText : line.presentation.plainText)
        needsLayout = true
        needsDisplay = true
    }

    /// Рамка значения: от колонки имени до правого края.
    private var valueRect: NSRect {
        let x = Metrics.RowPage.nameColumnWidth
        return NSRect(x: x, y: 0, width: max(0, bounds.width - x), height: bounds.height)
    }

    /// Под значением открываются окна правки.
    var valueAnchor: NSView { self }

    override func layout() {
        super.layout()
        let metrics = Metrics.RowPage.self
        icon.frame = NSRect(x: 0, y: (bounds.height - metrics.iconSize) / 2, width: metrics.iconSize, height: metrics.iconSize)
        let nameX = metrics.iconSize + metrics.iconToNameSpacing
        let labelHeight = nameLabel.intrinsicContentSize.height
        nameLabel.frame = NSRect(x: nameX, y: (bounds.height - labelHeight) / 2, width: metrics.nameColumnWidth - nameX - metrics.hoverPadding,
                                 height: labelHeight)
        let value = valueRect.insetBy(dx: metrics.hoverPadding, dy: 0)
        valueLabel.frame = NSRect(x: value.minX, y: (bounds.height - labelHeight) / 2, width: value.width, height: labelHeight)
        let box = Metrics.DatabaseGrid.checkboxSize
        checkbox.frame = NSRect(x: value.minX, y: (bounds.height - box) / 2, width: box, height: box)
        var chipX = value.minX
        for chip in chipViews {
            let size = OptionChip.size(for: chip.title)
            chip.frame = NSRect(x: chipX, y: (bounds.height - size.height) / 2, width: min(size.width, max(0, value.maxX - chipX)), height: size.height)
            chipX += size.width + Metrics.DatabaseGrid.chipSpacing
        }
        editor?.frame = NSRect(x: value.minX - 2, y: (bounds.height - labelHeight) / 2 - 1, width: value.width + 2, height: labelHeight + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isValueHovered || isEditing, isEditable else { return }
        let metrics = Metrics.RowPage.self
        Palette.hoverBackground.setFill()
        NSBezierPath(roundedRect: valueRect.insetBy(dx: 0, dy: 2), xRadius: metrics.hoverCornerRadius, yRadius: metrics.hoverCornerRadius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { isValueHovered = valueRect.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { isValueHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard valueRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        pressValue()
    }

    override func accessibilityPerformPress() -> Bool {
        pressValue()
        return true
    }

    /// Щелчок по значению — правка по типу.
    func pressValue() {
        switch line.editing {
        case .field: if !isEditing { onAction?(.beginEditing) }
        case .toggle: onAction?(.toggle)
        case .popup: onAction?(.openEditor)
        case .readOnly: break
        }
    }

    /// Поле правки на месте значения с текстом `text`, курсор в конце.
    func beginEditing(text: String) {
        guard editor == nil else { return }
        let field = NSTextField(string: text)
        field.font = NSFont.systemFont(ofSize: Metrics.RowPage.fontSize)
        field.textColor = Palette.textPrimary
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.setAccessibilityIdentifier("row-property-editor")
        editor = field
        editStartText = text
        valueLabel.isHidden = true
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        needsDisplay = true
    }

    /// Enter и Esc — готово (как у Notion: Esc не отменяет набранное).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        finishEditing()
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) { finishEditing() }

    func finishEditing() {
        guard let field = editor else { return }
        editor = nil
        let text = field.stringValue
        field.delegate = nil
        if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        field.removeFromSuperview()
        valueLabel.isHidden = false
        needsDisplay = true
        onAction?(.endEditing(text: text, changed: text != editStartText))
    }
}

/// Флажок значения — как в ячейке таблицы.
@MainActor
final class RowCheckboxView: NSView {
    var isChecked = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// Щелчок принимает строка свойства.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Metrics.DatabaseGrid.checkboxCornerRadius
        let box = bounds.insetBy(dx: 0.6, dy: 0.6)
        let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        if isChecked {
            Palette.checkboxChecked.setFill()
            path.fill()
            let mark = NSBezierPath()
            mark.lineWidth = 1.6
            mark.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
            mark.line(to: NSPoint(x: box.minX + 6.8, y: box.maxY - 4))
            mark.line(to: NSPoint(x: box.maxX - 3.2, y: box.minY + 4))
            Palette.checkboxCheckmark.setStroke()
            mark.stroke()
        } else {
            path.lineWidth = 1.2
            Palette.textSecondary.setStroke()
            path.stroke()
        }
    }
}

/// «+ Добавить свойство» серым; под мышью — подложка.
@MainActor
final class RowAddPropertyButton: NSView {
    static let title = "Добавить свойство"
    var onPress: (() -> Void)?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: RowAddPropertyButton.title)
    private var isHovered = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Metrics.RowPage.iconSize - 3, weight: .regular))
        icon.contentTintColor = Palette.textSecondary
        label.font = NSFont.systemFont(ofSize: Metrics.RowPage.fontSize)
        label.textColor = Palette.textSecondary
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.title)
        setAccessibilityIdentifier("row-add-property")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var fittingWidth: CGFloat {
        Metrics.RowPage.iconSize + Metrics.RowPage.iconToNameSpacing + ceil(label.intrinsicContentSize.width) + Metrics.RowPage.hoverPadding
    }

    override func layout() {
        super.layout()
        let metrics = Metrics.RowPage.self
        icon.frame = NSRect(x: 0, y: (bounds.height - metrics.iconSize) / 2, width: metrics.iconSize, height: metrics.iconSize)
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: metrics.iconSize + metrics.iconToNameSpacing, y: (bounds.height - height) / 2,
                             width: ceil(label.intrinsicContentSize.width), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        let metrics = Metrics.RowPage.self
        Palette.hoverBackground.setFill()
        let rect = bounds.insetBy(dx: 0, dy: 2).offsetBy(dx: -metrics.hoverPadding / 2, dy: 0)
        NSBezierPath(roundedRect: rect, xRadius: metrics.hoverCornerRadius, yRadius: metrics.hoverCornerRadius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
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
}
