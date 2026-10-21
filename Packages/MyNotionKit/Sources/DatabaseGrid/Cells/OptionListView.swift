import AppKit
import Databases
import NotesCore
import VisualStyle

/// Список вариантов окна ячейки и настроек свойства (`notion-select-cell-popup.png`, `notion-edit-property-status.png`):
/// разделы (у статуса — группы с заголовком и «+»), строка — ручка «⠿», плашка, справа «⋯» при наведении (окно ячейки)
/// или «›» (настройки). Ручкой вариант перетаскивается — в том числе в другую группу статуса.
@MainActor
final class OptionListView: NSView {
    enum Style { case picker, settings }

    struct Section {
        var group: StatusGroup?
        var title: String?
        var options: [SelectOption]
        /// «+» у заголовка — новый вариант в группе (настройки статуса).
        var addable = false
    }

    static let rowHeight = PropertyPopupMetrics.rowHeight
    static let captionHeight = PropertyPopupMetrics.captionHeight

    let style: Style
    let isStatus: Bool
    private(set) var sections: [Section] = []
    private var rows: [OptionRowView] = []
    private var captions: [OptionCaptionView] = []
    var highlightedId: UUID? { didSet { rows.forEach { $0.isHighlighted = $0.option.id == highlightedId } } }
    /// Выбранные в ячейке — подложкой (как у Notion выбранный вариант).
    var onPick: ((SelectOption) -> Void)?
    var onMenu: ((SelectOption, NSView) -> Void)?
    var onMove: ((SelectOption, UUID?, StatusGroup?) -> Void)?
    var onAdd: ((StatusGroup?) -> Void)?

    private var dropLine: CGFloat? { didSet { needsDisplay = true } }
    private var dragging: SelectOption?

    init(style: Style, isStatus: Bool) {
        self.style = style
        self.isStatus = isStatus
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var options: [SelectOption] { sections.flatMap(\.options) }

    var contentHeight: CGFloat {
        sections.reduce(0) { total, section in
            total + (section.title == nil ? 0 : Self.captionHeight) + CGFloat(section.options.count) * Self.rowHeight
        }
    }

    func setSections(_ sections: [Section]) {
        self.sections = sections
        rows.forEach { $0.removeFromSuperview() }
        captions.forEach { $0.removeFromSuperview() }
        rows = []
        captions = []
        for section in sections {
            if let title = section.title {
                let caption = OptionCaptionView(title: title, addable: section.addable, group: section.group)
                caption.onAdd = { [weak self] in self?.onAdd?(section.group) }
                addSubview(caption)
                captions.append(caption)
            }
            for option in section.options {
                let row = OptionRowView(option: option, style: style, isStatus: isStatus)
                row.isHighlighted = option.id == highlightedId
                row.onPress = { [weak self, weak row] in
                    guard let self, let row else { return }
                    if self.style == .settings { self.onMenu?(option, row) } else { self.onPick?(option) }
                }
                row.onMenu = { [weak self, weak row] in
                    guard let self, let row else { return }
                    self.onMenu?(option, row)
                }
                row.onDrag = { [weak self] phase, point in self?.drag(option, phase, at: point) }
                addSubview(row)
                rows.append(row)
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        var captionIndex = 0
        var rowIndex = 0
        for section in sections {
            if section.title != nil {
                captions[captionIndex].frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.captionHeight)
                captionIndex += 1
                y += Self.captionHeight
            }
            for _ in section.options {
                rows[rowIndex].frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
                rowIndex += 1
                y += Self.rowHeight
            }
        }
    }

    /// Рамка строки варианта (для окна «⋯» и прокрутки к подсвеченному).
    func rowView(of id: UUID) -> NSView? { rows.first { $0.option.id == id } }

    // MARK: Перетаскивание

    /// Места, куда можно положить вариант: начало каждого раздела и после каждой строки.
    private var slots: [(group: StatusGroup?, after: UUID?, y: CGFloat)] {
        var result: [(StatusGroup?, UUID?, CGFloat)] = []
        var y: CGFloat = 0
        for section in sections {
            if section.title != nil { y += Self.captionHeight }
            result.append((section.group, nil, y))
            for option in section.options {
                y += Self.rowHeight
                result.append((section.group, option.id, y))
            }
        }
        return result
    }

    private func drag(_ option: SelectOption, _ phase: OptionRowView.DragPhase, at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        let nearest = slots.min { abs($0.y - point.y) < abs($1.y - point.y) }
        switch phase {
        case .moved:
            dragging = option
            dropLine = nearest?.y
        case .ended:
            defer { dragging = nil; dropLine = nil }
            guard dragging?.id == option.id, let nearest, nearest.after != option.id else { return }
            onMove?(option, nearest.after, isStatus ? nearest.group : nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let dropLine else { return }
        Palette.dropIndicator.setFill()
        NSRect(x: PropertyPopupMetrics.padding, y: dropLine - 1, width: bounds.width - 2 * PropertyPopupMetrics.padding, height: 2).fill()
    }
}

/// Заголовок раздела списка вариантов: «К выполнению», «Варианты»; «+» справа у групп статуса в настройках.
@MainActor
final class OptionCaptionView: NSView {
    let title: String
    private let addButton: NSButton?
    var onAdd: (() -> Void)?

    init(title: String, addable: Bool, group: StatusGroup?) {
        self.title = title
        addButton = addable ? NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Добавить вариант") ?? NSImage(),
                                       target: nil, action: nil) : nil
        super.init(frame: .zero)
        if let addButton {
            addButton.isBordered = false
            addButton.contentTintColor = Palette.textSecondary
            addButton.target = self
            addButton.action = #selector(add)
            addButton.setAccessibilityIdentifier("option-group-add-\(group?.rawValue ?? "all")")
            addSubview(addButton)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    @objc private func add() { onAdd?() }

    override func layout() {
        super.layout()
        addButton?.frame = NSRect(x: bounds.maxX - PropertyPopupMetrics.padding - 18, y: (bounds.height - 18) / 2 + 2, width: 18, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: Palette.textSecondary])
            .draw(at: NSPoint(x: PropertyPopupMetrics.padding, y: bounds.height - font.ascender + font.descender - 6))
    }
}

/// Строка варианта: «⠿», плашка, «⋯» при наведении или «›».
@MainActor
final class OptionRowView: NSView {
    enum DragPhase { case moved, ended }

    let option: SelectOption
    let style: OptionListView.Style
    let isStatus: Bool
    var isHighlighted = false { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    var onMenu: (() -> Void)?
    var onDrag: ((DragPhase, NSPoint) -> Void)?
    private var dragStart: NSPoint?
    private var isDragging = false

    static let handleWidth: CGFloat = 18

    init(option: SelectOption, style: OptionListView.Style, isStatus: Bool) {
        self.option = option
        self.style = style
        self.isStatus = isStatus
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(option.name)
        setAccessibilityIdentifier("option-row-\(option.name)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var handleRect: NSRect { NSRect(x: 4, y: 0, width: Self.handleWidth, height: bounds.height) }
    private var menuRect: NSRect { NSRect(x: bounds.maxX - 30, y: (bounds.height - 22) / 2, width: 22, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let highlight = NSRect(x: PropertyPopupMetrics.inset, y: 1, width: bounds.width - 2 * PropertyPopupMetrics.inset, height: bounds.height - 2)
        if isHighlighted || isHovered {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: highlight, xRadius: Metrics.PopupMenu.rowCornerRadius, yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        ActionMenuIcon.draw("circle.grid.2x3.fill", color: Palette.handleIcon, in: handleRect.insetBy(dx: 2, dy: (bounds.height - 14) / 2), inkSide: 10)
        let chipX = handleRect.maxX + 4
        let maxWidth = bounds.width - chipX - 40
        if isStatus {
            let size = CellChipStyles.statusSize(option.name)
            CellChipStyles.drawStatus(title: option.name, color: option.optionColor,
                                      in: NSRect(x: chipX, y: (bounds.height - size.height) / 2, width: min(size.width, maxWidth), height: size.height))
        } else {
            let size = OptionChip.size(for: option.name)
            OptionChip.draw(title: option.name, color: option.optionColor,
                            in: NSRect(x: chipX, y: (bounds.height - size.height) / 2, width: min(size.width, maxWidth), height: size.height))
        }
        switch style {
        case .picker where isHovered || isHighlighted:
            ActionMenuIcon.draw("ellipsis", color: Palette.textSecondary, in: menuRect, inkSide: 14)
        case .settings:
            ActionMenuIcon.drawChevron(in: NSRect(x: bounds.maxX - PropertyPopupMetrics.padding - 16, y: (bounds.height - 16) / 2, width: 16, height: 16))
        default: break
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = handleRect.contains(point) ? event.locationInWindow : nil
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        if !isDragging, hypot(event.locationInWindow.x - dragStart.x, event.locationInWindow.y - dragStart.y) < 3 { return }
        isDragging = true
        onDrag?(.moved, event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; isDragging = false }
        if isDragging {
            onDrag?(.ended, event.locationInWindow)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if style == .picker, menuRect.insetBy(dx: -4, dy: -4).contains(point) { onMenu?() } else { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func accessibilityChildren() -> [Any]? { nil }
}

/// Меню «⋯» варианта (`notion-select-option-colors.png`): поле имени, «Удалить», «Цвета» — 10 цветов с образцом и
/// галочкой у текущего. Имя пишется по Enter и уходу из поля.
@MainActor
final class OptionMenuView: NSView {
    static let width: CGFloat = 220
    private let stack = PropertyPopupStack()
    let nameField: PropertyPopupField
    private var colorRows: [ChoiceRow] = []
    var onRename: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onColor: ((OptionColor) -> Void)?
    private let initialName: String

    init(option: SelectOption) {
        initialName = option.name
        nameField = PropertyPopupField(text: option.name, placeholder: "Название варианта", identifier: "option-menu-name")
        super.init(frame: .zero)
        addSubview(stack)
        stack.topPadding = 6
        nameField.onCommand = { [weak self] selector in
            guard let self else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                self.commitName()
                self.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
        nameField.onEndEditing = { [weak self] _ in self?.commitName() }
        stack.append(nameField, height: PropertyPopupMetrics.nameBlockHeight)
        let delete = ChoiceRow(title: "Удалить", icon: "trash", identifier: "option-menu-delete")
        delete.onPress = { [weak self] in self?.onDelete?() }
        stack.append(delete, height: PropertyPopupMetrics.rowHeight)
        stack.append(PropertyPopupSeparator(), height: PropertyPopupMetrics.separatorHeight)
        stack.append(PropertyPopupCaption("Цвета"), height: PropertyPopupMetrics.captionHeight)
        for color in OptionColor.allCases {
            let row = ChoiceRow(title: color.title, swatch: color, isChecked: color == option.optionColor, identifier: "option-color-\(color.rawValue)")
            row.onPress = { [weak self] in
                self?.colorRows.forEach { $0.isChecked = $0.swatch == color }
                self?.onColor?(color)
            }
            stack.append(row, height: PropertyPopupMetrics.rowHeight)
            colorRows.append(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var preferredSize: NSSize { NSSize(width: Self.width, height: stack.contentHeight + 6) }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    private var committed: String?

    private func commitName() {
        let name = nameField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != initialName, name != committed else { return }
        committed = name
        onRename?(name)
    }
}
