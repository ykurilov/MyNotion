import AppKit
import Databases
import NotesCore
import VisualStyle

/// Окно ячейки выбора, множественного выбора и статуса (spec US2, сценарии 1–3; `notion-select-cell-popup.png`,
/// `notion-status-cell-popup.png`): сверху выбранное плашками с «×» и поле «Найти вариант…», под ним «Выберите вариант
/// или создайте его» и варианты (у статуса — по группам), внизу «Создать …», если точного варианта нет. ↑↓ — по списку,
/// Enter — выбрать или создать (у выбора и статуса окно закрывается, у множественного — остаётся), ⌫ в пустом поле
/// снимает последний выбранный, Esc — закрыть. «⋯» у варианта — имя, удалить, цвет.
@MainActor
final class OptionPickerView: NSView, CellPopupContent {
    nonisolated static let factory = CellPopupFactory(kinds: [.select, .multiSelect, .status]) { OptionPickerView(context: $0) }

    static let width: CGFloat = 280
    static let maxListHeight: CGFloat = 320

    private let context: CellPopupContext
    private let searchBox: OptionSearchBox
    private let caption = PropertyPopupCaption("Выберите вариант или создайте его")
    private let scroll = NSScrollView()
    private let list: OptionListView
    private let createRow = OptionCreateRow()
    private let menuCard = PopupCard()
    private var propertyContext: PropertyContext?
    private var kind: PropertyKind
    private var chosen: [SelectOption] = []
    private var shown: [SelectOption] = []
    private var highlighted = 0
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(context: CellPopupContext) {
        self.context = context
        let fresh = context.freshContext()
        propertyContext = fresh
        kind = fresh?.property.kind ?? .select
        list = OptionListView(style: .picker, isStatus: kind == .status)
        searchBox = OptionSearchBox(placeholder: "Найти вариант…")
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        setAccessibilityIdentifier("option-picker")
        addSubview(searchBox)
        if kind != .status { addSubview(caption) }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        addSubview(scroll)
        addSubview(createRow)
        searchBox.text = context.initialText ?? ""
        searchBox.onChange = { [weak self] _ in self?.highlighted = 0; self?.reload() }
        searchBox.onCommand = { [weak self] selector in self?.handle(selector) ?? false }
        searchBox.onRemove = { [weak self] option in self?.remove(option) }
        list.onPick = { [weak self] option in self?.pick(option) }
        list.onMenu = { [weak self] option, row in self?.showMenu(for: option, besides: row) }
        list.onMove = { [weak self] option, after, group in
            guard let self else { return }
            self.context.attempt { try self.context.operations.moveOption(option.id, after: after, group: group) }
        }
        createRow.onPress = { [weak self] in self?.createFromQuery() }
        observer = NotificationCenter.default.addObserver(forName: DatabaseOperations.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    func focusFirstField() { searchBox.focus() }

    /// Галерея: меню «⋯» первого варианта списка.
    func showMenuForFirstOption() {
        guard let option = list.options.first, let row = list.rowView(of: option.id) else { return }
        showMenu(for: option, besides: row)
    }

    /// Галерея: набрать текст в поиске.
    func search(_ text: String) {
        searchBox.text = text
        highlighted = 0
        reload()
    }

    // MARK: Данные

    private var query: String { searchBox.text }
    private var offersCreation: Bool { propertyContext.map { OptionList.offersCreation(query, in: $0) } ?? false }

    /// Перечитать варианты и значение ячейки (после правки здесь, в другом окне или с другого Mac).
    func reload() {
        let previousHeight = preferredSize.height
        guard let fresh = context.freshContext() else { return context.close() }
        propertyContext = fresh
        let value = context.cellValue()
        let ids = (value?.array ?? value.map { [$0] } ?? []).compactMap { $0.string.flatMap(UUID.init(uuidString:)) }
        chosen = ids.compactMap { id in fresh.options.first { $0.id == id } }
        shown = OptionList.matching(query, in: fresh)
        searchBox.isStatus = kind == .status
        searchBox.chips = chosen
        if kind == .status {
            list.setSections(StatusGroup.allCases.map { group in
                OptionListView.Section(group: group, title: group.title, options: shown.filter { ($0.statusGroup ?? .todo) == group })
            }.filter { !$0.options.isEmpty || query.isEmpty })
            shown = list.options
        } else {
            list.setSections([OptionListView.Section(group: nil, title: nil, options: shown)])
        }
        createRow.isHidden = !offersCreation
        createRow.preview = (query.trimmingCharacters(in: .whitespacesAndNewlines), kind == .status)
        highlighted = min(highlighted, max(0, rowCount - 1))
        applyHighlight()
        needsLayout = true
        if preferredSize.height != previousHeight, window != nil { context.resize() }
    }

    private var rowCount: Int { shown.count + (offersCreation ? 1 : 0) }

    private func applyHighlight() {
        list.highlightedId = highlighted < shown.count ? shown[highlighted].id : nil
        createRow.isHighlighted = offersCreation && highlighted == shown.count
        if let id = list.highlightedId, let row = list.rowView(of: id) { list.scrollToVisible(row.frame) }
    }

    // MARK: Размеры

    private var listHeight: CGFloat { min(Self.maxListHeight, list.contentHeight) }
    private var captionHeight: CGFloat { kind == .status ? 0 : PropertyPopupMetrics.captionHeight }

    var preferredSize: NSSize {
        NSSize(width: Self.width, height: searchBox.height(forWidth: Self.width) + captionHeight + listHeight
               + (offersCreation ? PropertyPopupMetrics.rowHeight : 0) + 8)
    }

    override var fittingSize: NSSize { preferredSize }

    override func layout() {
        super.layout()
        let boxHeight = searchBox.height(forWidth: bounds.width)
        searchBox.frame = NSRect(x: 0, y: 0, width: bounds.width, height: boxHeight)
        var y = boxHeight + 4
        caption.frame = NSRect(x: PropertyPopupMetrics.inset, y: y, width: bounds.width - 2 * PropertyPopupMetrics.inset, height: captionHeight)
        y += captionHeight
        scroll.frame = NSRect(x: 0, y: y, width: bounds.width, height: listHeight)
        list.frame = NSRect(x: 0, y: 0, width: bounds.width - (list.contentHeight > Self.maxListHeight ? 8 : 0), height: list.contentHeight)
        y += listHeight
        createRow.frame = NSRect(x: PropertyPopupMetrics.inset, y: y, width: bounds.width - 2 * PropertyPopupMetrics.inset, height: PropertyPopupMetrics.rowHeight)
    }

    // MARK: Действия

    private func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if rowCount > 0 { highlighted = (highlighted + 1) % rowCount }
            applyHighlight()
        case #selector(NSResponder.moveUp(_:)):
            if rowCount > 0 { highlighted = (highlighted - 1 + rowCount) % rowCount }
            applyHighlight()
        case #selector(NSResponder.insertNewline(_:)):
            if highlighted < shown.count { pick(shown[highlighted]) } else if offersCreation { createFromQuery() }
        case #selector(NSResponder.cancelOperation(_:)):
            context.close()
        case #selector(NSResponder.deleteBackward(_:)):
            guard query.isEmpty, let last = chosen.last else { return false }
            remove(last)
        default:
            return false
        }
        return true
    }

    private func pick(_ option: SelectOption) {
        let isChosen = chosen.contains { $0.id == option.id }
        if kind != .multiSelect, isChosen { return context.close() }
        context.attempt { try context.operations.pickOption(option.id, rowId: context.rowId, propertyId: context.propertyId) }
        finishChoice()
    }

    private func createFromQuery() {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        context.attempt { _ = try context.operations.pickOption(named: name, rowId: context.rowId, propertyId: context.propertyId) }
        finishChoice()
    }

    /// После выбора: у выбора и статуса окно закрывается, у множественного — поле очищается для следующего.
    private func finishChoice() {
        guard kind == .multiSelect else { return context.close() }
        searchBox.text = ""
        highlighted = 0
        reload()
        searchBox.focus()
    }

    private func remove(_ option: SelectOption) {
        context.attempt { try context.operations.removeOption(option.id, rowId: context.rowId, propertyId: context.propertyId) }
        reload()
    }

    func showMenu(for option: SelectOption, besides row: NSView) {
        let menu = OptionMenuView(option: option)
        let operations = context.operations
        let context = context
        menu.onRename = { name in context.attempt { try operations.renameOption(option.id, to: name) } }
        menu.onColor = { color in context.attempt { try operations.setOptionColor(option.id, to: color) } }
        menu.onDelete = { [weak self] in
            context.attempt { try operations.deleteOption(option.id) }
            self?.menuCard.close()
        }
        menuCard.onClose = { [weak self] in self?.searchBox.focus() }
        menuCard.show(menu, size: menu.preferredSize, besides: row, gap: 0)
        menu.nameField.focus()
    }
}

/// Верх окна выбора: выбранные плашки с «×» и поле поиска в одной области с переносом (как у Notion).
@MainActor
final class OptionSearchBox: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private var chipViews: [RemovableChipView] = []
    var chips: [SelectOption] = [] { didSet { rebuildChips() } }
    var isStatus = false
    var onChange: ((String) -> Void)?
    var onCommand: ((Selector) -> Bool)?
    var onRemove: ((SelectOption) -> Void)?

    static let lineHeight: CGFloat = 28
    static let padding: CGFloat = 8

    init(placeholder: String) {
        super.init(frame: .zero)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.popupMenuTitle.font
        field.textColor = Palette.textPrimary
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityIdentifier("option-search")
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    private func rebuildChips() {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews = chips.map { option in
            let view = RemovableChipView(option: option, isStatus: isStatus)
            view.onRemove = { [weak self] in self?.onRemove?(option) }
            addSubview(view)
            return view
        }
        needsLayout = true
    }

    /// Раскладка плашек и поля в строки по ширине: поле занимает остаток строки, но не уже 100.
    private func frames(forWidth width: CGFloat) -> (chips: [NSRect], field: NSRect, height: CGFloat) {
        var x = Self.padding, y: CGFloat = 4
        var rects: [NSRect] = []
        for view in chipViews {
            let size = view.preferredSize
            if x + size.width > width - Self.padding, x > Self.padding {
                x = Self.padding
                y += Self.lineHeight
            }
            rects.append(NSRect(x: x, y: y + (Self.lineHeight - size.height) / 2, width: min(size.width, width - 2 * Self.padding), height: size.height))
            x += size.width + 4
        }
        if width - Self.padding - x < 100 {
            x = Self.padding
            y += Self.lineHeight
        }
        let fieldRect = NSRect(x: x, y: y + (Self.lineHeight - 20) / 2, width: width - Self.padding - x, height: 20)
        return (rects, fieldRect, y + Self.lineHeight + 4)
    }

    func height(forWidth width: CGFloat) -> CGFloat { frames(forWidth: width).height }

    override func layout() {
        super.layout()
        let layout = frames(forWidth: bounds.width)
        for (view, rect) in zip(chipViews, layout.chips) { view.frame = rect }
        field.frame = layout.field
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.emojiSearchBackground.setFill()
        bounds.fill()
        Palette.popupDivider.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        onCommand?(commandSelector) ?? false
    }
}

/// Выбранная плашка в окне с «×» справа.
@MainActor
final class RemovableChipView: NSView {
    let option: SelectOption
    let isStatus: Bool
    var onRemove: (() -> Void)?
    static let removeWidth: CGFloat = 16

    init(option: SelectOption, isStatus: Bool) {
        self.option = option
        self.isStatus = isStatus
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Снять «\(option.name)»")
        setAccessibilityIdentifier("chosen-\(option.name)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var preferredSize: NSSize {
        let base = isStatus ? CellChipStyles.statusSize(option.name) : OptionChip.size(for: option.name)
        return NSSize(width: base.width + Self.removeWidth, height: base.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isStatus {
            CellChipStyles.drawStatus(title: option.name, color: option.optionColor, in: bounds)
        } else {
            OptionChip.draw(title: option.name, color: option.optionColor, in: bounds)
        }
        // Текст плашки уже нарисован с полем; «×» — в правом поле.
        ActionMenuIcon.draw("xmark", color: Palette.textSecondary,
                            in: NSRect(x: bounds.maxX - Self.removeWidth - 1, y: (bounds.height - 12) / 2, width: 12, height: 12), inkSide: 8)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onRemove?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onRemove?()
        return true
    }
}

/// «Создать <плашка>» внизу окна: плашка будущего варианта цвета «По умолчанию».
@MainActor
final class OptionCreateRow: NSView {
    var preview: (name: String, isStatus: Bool) = ("", false) { didSet { needsDisplay = true; setAccessibilityLabel("Создать \(preview.name)") } }
    var isHighlighted = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("option-create")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            Palette.hoverBackground.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: Metrics.PopupMenu.rowCornerRadius, yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
        }
        let style = Typography.popupMenuTitle
        let label = NSAttributedString(string: "Создать", attributes: [.font: style.font, .foregroundColor: Palette.textSecondary])
        label.draw(at: NSPoint(x: PropertyPopupMetrics.padding, y: (bounds.height - style.lineHeight) / 2))
        let x = PropertyPopupMetrics.padding + label.size().width + 8
        let maxWidth = bounds.width - x - PropertyPopupMetrics.padding
        if preview.isStatus {
            let size = CellChipStyles.statusSize(preview.name)
            CellChipStyles.drawStatus(title: preview.name, color: .default,
                                      in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: min(size.width, maxWidth), height: size.height))
        } else {
            let size = OptionChip.size(for: preview.name)
            OptionChip.draw(title: preview.name, color: .default,
                            in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: min(size.width, maxWidth), height: size.height))
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
