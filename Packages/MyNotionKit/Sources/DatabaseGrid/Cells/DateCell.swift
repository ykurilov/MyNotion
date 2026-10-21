import AppKit
import Databases
import NotesCore
import VisualStyle

/// Окно ячейки даты (spec US2, сценарий 4; `notion-date-format-options.png`): поле даты (и конца), месяц с «Сегодня»
/// и «‹ ›», календарь с понедельника, «Дата окончания», «Формат даты ›», «Включить время», «Напомнить ›», «Очистить».
/// Каждая правка пишется сразу (свой шаг ⌘Z), как у Notion.
@MainActor
final class DateCellView: NSView, CellPopupContent {
    nonisolated static let factory = CellPopupFactory(kinds: [.date]) { DateCellView(context: $0) }
    /// Первое «Напомнить» — спросить разрешение macOS на уведомления (ставит приложение, `ReminderNotifications`).
    static var requestReminderPermission: (@MainActor () -> Void)?

    static let width: CGFloat = 264

    private let context: CellPopupContext
    private var value: DateCellValue?
    private var editingEnd = false
    private var month: (year: Int, month: Int)
    private let calendar: Calendar
    private let startField: DateTextField
    private let endField: DateTextField
    private let monthHeader = MonthHeaderView()
    private let grid: CalendarGridView
    private let stack = PropertyPopupStack()
    private let endToggle = PopupToggleRow(title: "Дата окончания", isOn: false, identifier: "date-end-toggle")
    private let formatRow = ChoiceRow(title: "Формат даты", identifier: "date-format")
    private let timeToggle = PopupToggleRow(title: "Включить время", isOn: false, identifier: "date-time-toggle")
    private let remindRow = ChoiceRow(title: "Напомнить", identifier: "date-remind")
    private let clearRow = ChoiceRow(title: "Очистить", identifier: "date-clear")
    private let submenu = PopupCard()

    init(context: CellPopupContext) {
        self.context = context
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.locale = Locale.current
        self.calendar = calendar
        value = DateCellValue(json: context.cellValue())
        let today = DateParts(Date(), calendar: calendar)
        let shownDay = value?.start ?? today
        month = (shownDay.year, shownDay.month)
        startField = DateTextField(identifier: "date-start-field")
        endField = DateTextField(identifier: "date-end-field")
        grid = CalendarGridView(calendar: calendar)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400))
        setAccessibilityIdentifier("date-popup")
        addSubview(startField)
        addSubview(endField)
        addSubview(monthHeader)
        addSubview(grid)
        addSubview(stack)
        stack.topPadding = 0
        for row in [formatRow, remindRow] { row.showsChevron = true }
        stack.append(PropertyPopupSeparator(), height: PropertyPopupMetrics.separatorHeight)
        stack.append(endToggle, height: PropertyPopupMetrics.rowHeight)
        stack.append(formatRow, height: PropertyPopupMetrics.rowHeight)
        stack.append(timeToggle, height: PropertyPopupMetrics.rowHeight)
        stack.append(remindRow, height: PropertyPopupMetrics.rowHeight)
        stack.append(PropertyPopupSeparator(), height: PropertyPopupMetrics.separatorHeight)
        stack.append(clearRow, height: PropertyPopupMetrics.rowHeight)

        startField.onCommit = { [weak self] text in self?.typed(text, forEnd: false) }
        endField.onCommit = { [weak self] text in self?.typed(text, forEnd: true) }
        startField.onFocus = { [weak self] in self?.editingEnd = false; self?.refresh() }
        endField.onFocus = { [weak self] in self?.editingEnd = true; self?.refresh() }
        startField.onCancel = { [weak self] in self?.context.close() }
        endField.onCancel = { [weak self] in self?.context.close() }
        monthHeader.onStep = { [weak self] step in self?.stepMonth(step) }
        monthHeader.onToday = { [weak self] in
            guard let self else { return }
            let today = DateParts(Date(), calendar: self.calendar)
            self.month = (today.year, today.month)
            self.pick(today)
        }
        grid.onPick = { [weak self] day in self?.pick(day) }
        endToggle.onToggle = { [weak self] on in self?.edit { $0.setHasEnd(on) }; self?.editingEnd = on; self?.refresh() }
        timeToggle.onToggle = { [weak self] on in self?.edit { $0.setHasTime(on) } }
        formatRow.onPress = { [weak self] in self?.showFormats() }
        remindRow.onPress = { [weak self] in self?.showReminders() }
        clearRow.onPress = { [weak self] in
            guard let self else { return }
            self.context.attempt { try self.context.operations.setCell(rowId: self.context.rowId, propertyId: self.context.propertyId, value: nil) }
            self.context.close()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var zone: String { value?.timeZone ?? TimeZone.current.identifier }
    private var fieldsHeight: CGFloat { value?.end != nil ? 2 * 34 : 34 }

    var preferredSize: NSSize {
        NSSize(width: Self.width, height: 8 + fieldsHeight + MonthHeaderView.height + CalendarGridView.height + stack.contentHeight + 6)
    }

    override var fittingSize: NSSize { preferredSize }

    func focusFirstField() { startField.focus() }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        var y: CGFloat = 8
        startField.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: 30)
        y += 34
        endField.isHidden = value?.end == nil
        if value?.end != nil {
            endField.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: 30)
            y += 34
        }
        monthHeader.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: MonthHeaderView.height)
        y += MonthHeaderView.height
        grid.frame = NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: CalendarGridView.height)
        y += CalendarGridView.height
        stack.frame = NSRect(x: 0, y: y, width: bounds.width, height: stack.contentHeight)
    }

    // MARK: Правка

    /// Изменить значение и сразу записать.
    private func edit(_ change: (inout DateCellValue) -> Void) {
        var next = value ?? DateCellValue(day: DateParts(Date(), calendar: calendar), timeZone: TimeZone.current.identifier)
        change(&next)
        write(next)
    }

    private func write(_ next: DateCellValue) {
        let hadEnd = value?.end != nil
        value = next
        context.attempt { try context.operations.setCell(rowId: context.rowId, propertyId: context.propertyId, value: next.json) }
        refresh()
        if hadEnd != (next.end != nil) { context.resize() }
    }

    private func pick(_ day: DateParts) {
        if value == nil {
            write(DateCellValue(day: day, timeZone: TimeZone.current.identifier))
            return
        }
        edit { $0.pick(day, editingEnd: editingEnd && $0.end != nil) }
        // Конец выбран — следующий щелчок снова о начале (как у Notion: начало, затем конец).
        if editingEnd { editingEnd = false } else if value?.end != nil { editingEnd = true }
        refresh()
    }

    private func typed(_ text: String, forEnd: Bool) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var next = value ?? DateCellValue(day: DateParts(Date(), calendar: calendar), timeZone: TimeZone.current.identifier)
        guard next.type(text, forEnd: forEnd) else {
            NSSound.beep()
            refresh()
            return
        }
        month = ((forEnd ? next.end : next.start) ?? next.start).monthKey
        write(next)
    }

    private func stepMonth(_ step: Int) {
        var month = self.month.month + step, year = self.month.year
        if month < 1 { month = 12; year -= 1 }
        if month > 12 { month = 1; year += 1 }
        self.month = (year, month)
        refresh()
    }

    private func refresh() {
        let config = context.freshContext()?.config ?? .emptyObject
        startField.text = value.map { Self.fieldText($0.start, hasTime: $0.hasTime) } ?? ""
        endField.text = value?.end.map { Self.fieldText($0, hasTime: value?.hasTime ?? false) } ?? ""
        startField.isActive = !editingEnd
        endField.isActive = editingEnd
        monthHeader.title = MonthGrid.title(year: month.year, month: month.month, locale: .current)
        grid.show(year: month.year, month: month.month, start: value?.start, end: value?.end)
        endToggle.isOn = value?.end != nil
        timeToggle.isOn = value?.hasTime ?? false
        formatRow.detail = (DateDisplayFormat(rawValue: config["dateFormat"]?.string ?? "") ?? .full).title
        remindRow.detail = value?.reminder?.title(hasTime: value?.hasTime ?? false) ?? "Нет"
        formatRow.needsDisplay = true
        remindRow.needsDisplay = true
        needsLayout = true
    }

    /// Текст поля: «21.10.2026» или «21.10.2026 15:15» — так же он и вводится.
    static func fieldText(_ parts: DateParts, hasTime: Bool) -> String {
        let day = String(format: "%02d.%02d.%04d", parts.day, parts.month, parts.year)
        return hasTime ? day + String(format: " %02d:%02d", parts.hour, parts.minute) : day
    }

    // MARK: Подменю

    private func showFormats() {
        guard let property = context.freshContext()?.property else { return }
        let current = property.config["dateFormat"]?.string ?? DateDisplayFormat.full.rawValue
        let list = ChoiceListView(items: DateDisplayFormat.allCases.map { .init(id: $0.rawValue, title: $0.title) }, checked: current,
                                  width: 200, identifier: "date-format-list")
        list.onChoose = { [weak self] id in
            guard let self else { return }
            var config = property.config
            config["dateFormat"] = id == DateDisplayFormat.full.rawValue ? nil : .string(id)
            if config != property.config { self.context.attempt { try self.context.operations.setPropertyConfig(property.id, config) } }
            self.submenu.close()
            self.refresh()
        }
        submenu.show(list, size: list.preferredSize, besides: formatRow, gap: 0)
    }

    private func showReminders() {
        let hasTime = value?.hasTime ?? false
        let items = [ChoiceListView.Item(id: "none", title: "Нет")]
            + DateReminder.options(hasTime: hasTime).map { ChoiceListView.Item(id: $0.rawValue, title: $0.title(hasTime: hasTime)) }
        let list = ChoiceListView(items: items, checked: value?.reminder?.rawValue ?? "none", width: 220, identifier: "date-remind-list")
        list.onChoose = { [weak self] id in
            guard let self else { return }
            let reminder = DateReminder(rawValue: id)
            if reminder != nil, self.value?.reminder == nil { Self.requestReminderPermission?() }
            self.edit { $0.reminder = reminder }
            self.submenu.close()
        }
        submenu.show(list, size: list.preferredSize, besides: remindRow, gap: 0)
    }
}

private extension DateParts {
    var monthKey: (year: Int, month: Int) { (year, month) }
}

/// Поле даты окна: текст «21.10.2026 15:15», синяя рамка у того, что правится (начало или конец).
@MainActor
final class DateTextField: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    var onCommit: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onCancel: (() -> Void)?
    var isActive = false { didSet { needsDisplay = true } }
    private var lastText = ""

    init(identifier: String) {
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.popupMenuTitle.font
        field.textColor = Palette.textPrimary
        field.placeholderString = "ДД.ММ.ГГГГ"
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    var text: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            lastText = newValue
        }
    }

    func focus() {
        window?.makeFirstResponder(field)
    }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 8, y: (bounds.height - 20) / 2, width: bounds.width - 16, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Metrics.ActionMenu.searchCornerRadius, yRadius: Metrics.ActionMenu.searchCornerRadius)
        Palette.emojiSearchBackground.setFill()
        path.fill()
        path.lineWidth = isActive ? Metrics.ActionMenu.focusRingWidth : 1
        (isActive ? Palette.focusRing : Palette.searchFieldBorder).setStroke()
        path.stroke()
    }

    func controlTextDidBeginEditing(_ obj: Notification) { onFocus?() }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard field.stringValue != lastText else { return }
        lastText = field.stringValue
        onCommit?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            lastText = field.stringValue
            onCommit?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
            return true
        default:
            return false
        }
    }
}

/// «Октябрь 2026», «Сегодня», «‹ ›».
@MainActor
final class MonthHeaderView: NSView {
    static let height: CGFloat = 34
    var title = "" { didSet { needsDisplay = true } }
    var onStep: ((Int) -> Void)?
    var onToday: (() -> Void)?
    private let previous = NSButton()
    private let next = NSButton()
    private let today = NSButton(title: "Сегодня", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        for (button, symbol, label) in [(previous, "chevron.left", "Предыдущий месяц"), (next, "chevron.right", "Следующий месяц")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.isBordered = false
            button.contentTintColor = Palette.textSecondary
            button.target = self
            addSubview(button)
        }
        previous.action = #selector(goPrevious)
        next.action = #selector(goNext)
        previous.setAccessibilityIdentifier("date-previous-month")
        next.setAccessibilityIdentifier("date-next-month")
        today.isBordered = false
        today.font = NSFont.systemFont(ofSize: 12)
        today.contentTintColor = Palette.textSecondary
        today.target = self
        today.action = #selector(goToday)
        today.setAccessibilityIdentifier("date-today")
        addSubview(today)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    @objc private func goPrevious() { onStep?(-1) }
    @objc private func goNext() { onStep?(1) }
    @objc private func goToday() { onToday?() }

    override func layout() {
        super.layout()
        next.frame = NSRect(x: bounds.maxX - 22, y: 8, width: 20, height: 20)
        previous.frame = NSRect(x: next.frame.minX - 24, y: 8, width: 20, height: 20)
        let width = today.intrinsicContentSize.width
        today.frame = NSRect(x: previous.frame.minX - width - 8, y: 8, width: width, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: Palette.textPrimary])
            .draw(at: NSPoint(x: 4, y: (bounds.height - font.ascender + font.descender) / 2))
    }
}

/// Календарь месяца: дни недели и 6 недель с понедельника; выбранный день — синим кругом, дни диапазона — бледно-синим,
/// сегодня — синим текстом, чужой месяц — серым.
@MainActor
final class CalendarGridView: NSView {
    static let cell: CGFloat = 34
    static let height: CGFloat = 7 * 30 + 4
    private let calendar: Calendar
    private var days: [DateParts] = []
    private var month = 1
    private var start: DateParts?
    private var end: DateParts?
    var onPick: ((DateParts) -> Void)?

    init(calendar: Calendar) {
        self.calendar = calendar
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("date-calendar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    func show(year: Int, month: Int, start: DateParts?, end: DateParts?) {
        days = MonthGrid.days(year: year, month: month, calendar: calendar)
        self.month = month
        self.start = start?.sameDay
        self.end = end?.sameDay
        needsDisplay = true
    }

    private var columnWidth: CGFloat { bounds.width / 7 }
    private let rowHeight: CGFloat = 30

    private func rect(ofIndex index: Int) -> NSRect {
        NSRect(x: CGFloat(index % 7) * columnWidth, y: rowHeight * CGFloat(index / 7 + 1), width: columnWidth, height: rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let small = NSFont.systemFont(ofSize: 11)
        for (index, symbol) in MonthGrid.weekdaySymbols(calendar: calendar, locale: .current).enumerated() {
            let text = NSAttributedString(string: symbol, attributes: [.font: small, .foregroundColor: Palette.textSecondary])
            let size = text.size()
            text.draw(at: NSPoint(x: CGFloat(index) * columnWidth + (columnWidth - size.width) / 2, y: (rowHeight - size.height) / 2))
        }
        let today = DateParts(Date(), calendar: calendar).sameDay
        let font = NSFont.systemFont(ofSize: 13)
        for (index, day) in days.enumerated() {
            let cell = rect(ofIndex: index)
            let circle = NSRect(x: cell.midX - 13, y: cell.midY - 13, width: 26, height: 26)
            let isEdge = day == start || day == end
            if let start, let end, day > start, day < end {
                Palette.blockSelection.setFill()
                NSRect(x: cell.minX, y: circle.minY, width: cell.width, height: circle.height).fill()
            }
            if isEdge {
                Palette.focusRing.setFill()
                NSBezierPath(ovalIn: circle).fill()
            }
            let color: NSColor = isEdge ? .white : day == today ? Palette.focusRing : day.month == month ? Palette.textPrimary : Palette.textSecondary
            let text = NSAttributedString(string: "\(day.day)", attributes: [.font: day == today ? NSFont.systemFont(ofSize: 13, weight: .semibold) : font,
                                                                             .foregroundColor: color])
            let size = text.size()
            text.draw(at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = days.indices.first(where: { rect(ofIndex: $0).contains(point) }) else { return }
        onPick?(days[index])
    }
}
