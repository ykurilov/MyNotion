import AppKit
import NotesCore
import VisualStyle

/// Месяц в сетке календарика: 6 недель с понедельника, как у Notion; дни соседних месяцев — серые.
struct DatePickerMonth: Equatable {
    struct Day: Equatable {
        var year: Int
        var month: Int
        var day: Int
        var isInMonth: Bool
    }

    let year: Int
    let month: Int

    static let weekdayTitles = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
    private static let monthTitles = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь",
                                      "Октябрь", "Ноябрь", "Декабрь"]

    var title: String { "\(Self.monthTitles[month - 1]) \(year)" }
    var next: DatePickerMonth { month == 12 ? DatePickerMonth(year: year + 1, month: 1) : DatePickerMonth(year: year, month: month + 1) }
    var previous: DatePickerMonth { month == 1 ? DatePickerMonth(year: year - 1, month: 12) : DatePickerMonth(year: year, month: month - 1) }

    var days: [Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return [] }
        // Понедельник — 0.
        let lead = (calendar.component(.weekday, from: first) + 5) % 7
        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - lead, to: first) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return Day(year: parts.year!, month: parts.month!, day: parts.day!, isInMonth: parts.month == month)
        }
    }
}

/// Календарик даты (contracts/blocks-and-keys.md, «Даты и напоминания») по образцу Notion: поле даты и времени,
/// месяц со стрелками и «Сегодня», сетка, «Время», «Напомнить», «Удалить». Своё окно без рамки над страницей,
/// как меню «/»: системный календарь macOS выглядит иначе. Каждая правка сразу меняет дату в тексте.
@MainActor
final class DatePickerPopoverController {
    private var window: DatePickerWindow?
    private weak var textView: PageTextView?
    private(set) var dateId: UUID?
    private var mouseMonitor: Any?
    /// Подписка снимается в `deinit` — он не привязан к главному потоку.
    nonisolated(unsafe) private var deactivationObserver: NSObjectProtocol?

    deinit {
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }

    var isOpen: Bool { window?.isVisible == true }
    var card: DatePickerCard? { window?.card }

    func open(for date: DateMention, atCharacter index: Int, in textView: PageTextView) {
        close()
        self.textView = textView
        dateId = date.id
        let card = DatePickerCard(date: date, now: textView.now(), calendar: textView.calendar)
        card.onChange = { [weak self] edited in self?.textView?.replaceDate(edited.id, with: edited) }
        card.onReminderEnabled = { [weak self] in
            guard let request = self?.textView?.onRequestReminderPermission else { return true }
            return await request()
        }
        card.onDelete = { [weak self] in
            self?.textView?.replaceDate(date.id, with: nil)
            self?.close()
        }
        let window = DatePickerWindow(card: card)
        self.window = window
        guard let parent = textView.window else { return }
        let anchor = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        window.show(below: anchor, parent: parent)
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.window, self?.card?.isShowingMenu != true { self?.close() }
            return event
        }
        deactivationObserver = PopupWindows.onAppDeactivation { [weak self] in self?.close() }
    }

    func close() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        window?.hide()
        window = nil
    }

    /// Esc в тексте закрывает календарик.
    func handleCancel() -> Bool {
        guard isOpen else { return false }
        close()
        return true
    }
}

final class DatePickerWindow: NSPanel {
    let card: DatePickerCard

    init(card: DatePickerCard) {
        self.card = card
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        contentView = card
        setAccessibilityIdentifier("date-picker")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(below anchor: NSRect, parent: NSWindow) {
        let size = card.cardSize
        let margin = PopupMenuWindow.shadowMargin
        let spacing = Metrics.PopupMenu.anchorSpacing
        var origin = NSPoint(x: anchor.minX - margin, y: anchor.minY - spacing - size.height - margin)
        if let screen = parent.screen?.visibleFrame, origin.y + margin < screen.minY { origin.y = anchor.maxY + spacing - margin }
        setFrame(NSRect(x: origin.x, y: origin.y, width: size.width + 2 * margin, height: size.height + 2 * margin), display: true)
        PopupWindows.show(self, over: parent)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// Карточка календарика. Размеры сняты с Notion (снимок 18.10.2026 в виртуальном Mac): ширина 250, клетка дня 32.
@MainActor
final class DatePickerCard: NSView, NSTextFieldDelegate {
    private(set) var date: DateMention
    private let calendar: Calendar
    private let now: Date
    private(set) var shownMonth: DatePickerMonth
    var onChange: ((DateMention) -> Void)?
    var onReminderEnabled: (() async -> Bool)?
    var onDelete: (() -> Void)?
    private(set) var isShowingMenu = false
    /// Разрешение уведомлений не дали: под «Напомнить» — подсказка.
    private(set) var showsPermissionHint = false

    let dateField = NSTextField()
    let timeField = NSTextField()
    /// Прозрачная кнопка поверх строки «Напомнить»: её видят доступность и UI-тесты.
    private let reminderButton = NSButton(title: "", target: nil, action: nil)

    enum Layout {
        static let width: CGFloat = 250
        static let padding: CGFloat = 12
        static let fieldHeight: CGFloat = 28
        static let headerHeight: CGFloat = 30
        static let weekdayHeight: CGFloat = 24
        static let cell: CGFloat = 32
        static let rowHeight: CGFloat = 28
        static let dividerGap: CGFloat = 6
        static let hintHeight: CGFloat = 20
    }

    init(date: DateMention, now: Date, calendar: Calendar) {
        self.date = date
        self.now = now
        self.calendar = calendar
        let shown = date.shownComponents(in: calendar)
        shownMonth = DatePickerMonth(year: shown?.year ?? 2026, month: shown?.month ?? 1)
        super.init(frame: .zero)
        for field in [dateField, timeField] {
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = Typography.popupMenuTitle.font
            field.textColor = Palette.textPrimary
            field.delegate = self
            field.cell?.usesSingleLineMode = true
            addSubview(field)
        }
        reminderButton.isTransparent = true
        reminderButton.isBordered = false
        reminderButton.target = self
        reminderButton.action = #selector(reminderRowPressed)
        reminderButton.setAccessibilityIdentifier("date-picker-reminder")
        reminderButton.setAccessibilityLabel("Напомнить")
        addSubview(reminderButton)
        dateField.setAccessibilityIdentifier("date-picker-date-field")
        timeField.setAccessibilityIdentifier("date-picker-time")
        updateFields()
        frame.size = cardSize
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Календарь")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Геометрия

    var cardSize: NSSize {
        let grid = Layout.headerHeight + Layout.weekdayHeight + 6 * Layout.cell
        let rows = 2 * Layout.rowHeight + Layout.rowHeight + 2 * Layout.dividerGap + 1
        let height = Layout.padding + Layout.fieldHeight + 8 + grid + Layout.dividerGap * 2 + 1 + rows
            + (showsPermissionHint ? Layout.hintHeight : 0) + 6
        return NSSize(width: Layout.width, height: height)
    }

    private var card: NSRect {
        let margin = PopupMenuWindow.shadowMargin
        return NSRect(x: margin, y: margin, width: cardSize.width, height: cardSize.height)
    }

    private var fieldRect: NSRect {
        NSRect(x: card.minX + Layout.padding, y: card.minY + Layout.padding, width: card.width - 2 * Layout.padding, height: Layout.fieldHeight)
    }

    private var headerTop: CGFloat { fieldRect.maxY + 8 }
    private var gridTop: CGFloat { headerTop + Layout.headerHeight + Layout.weekdayHeight }
    private var gridLeft: CGFloat { card.minX + (card.width - 7 * Layout.cell) / 2 }
    private var dividerY: CGFloat { gridTop + 6 * Layout.cell + Layout.dividerGap }

    private func rowRect(_ index: Int) -> NSRect {
        // 0 — «Время», 1 — «Напомнить», 2 — «Удалить» (после черты).
        var top = dividerY + 1 + Layout.dividerGap + CGFloat(index) * Layout.rowHeight
        if index == 2 { top += (showsPermissionHint ? Layout.hintHeight : 0) + Layout.dividerGap * 2 + 1 }
        return NSRect(x: card.minX + 4, y: top, width: card.width - 8, height: Layout.rowHeight)
    }

    private var arrowRects: (previous: NSRect, next: NSRect, today: NSRect) {
        let y = headerTop + (Layout.headerHeight - 24) / 2
        let next = NSRect(x: card.maxX - Layout.padding - 22, y: y, width: 22, height: 24)
        let previous = next.offsetBy(dx: -26, dy: 0)
        let today = NSRect(x: previous.minX - 64, y: y, width: 60, height: 24)
        return (previous, next, today)
    }

    func dayRect(_ index: Int) -> NSRect {
        NSRect(x: gridLeft + CGFloat(index % 7) * Layout.cell, y: gridTop + CGFloat(index / 7) * Layout.cell,
               width: Layout.cell, height: Layout.cell)
    }

    override func layout() {
        super.layout()
        reminderButton.frame = rowRect(1)
        let field = fieldRect.insetBy(dx: 8, dy: (Layout.fieldHeight - 18) / 2)
        if date.includesTime {
            dateField.frame = NSRect(x: field.minX, y: field.minY, width: field.width * 0.58, height: 18)
            timeField.frame = NSRect(x: fieldRect.minX + fieldRect.width * 0.62, y: field.minY, width: field.width * 0.36, height: 18)
            timeField.isHidden = false
        } else {
            dateField.frame = NSRect(x: field.minX, y: field.minY, width: field.width, height: 18)
            timeField.isHidden = true
        }
    }

    // MARK: Рисование

    override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: card)
        // Поле даты: подложка hoverBackground, скругление 6; время — справа за чертой.
        Palette.hoverBackground.setFill()
        NSBezierPath(roundedRect: fieldRect, xRadius: 6, yRadius: 6).fill()
        if date.includesTime {
            Palette.border.setFill()
            NSRect(x: fieldRect.minX + fieldRect.width * 0.6, y: fieldRect.minY + 6, width: 1, height: fieldRect.height - 12).fill()
        }

        let header = NSAttributedString(string: shownMonth.title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: Palette.textPrimary,
        ])
        header.draw(at: NSPoint(x: card.minX + Layout.padding + 2, y: headerTop + (Layout.headerHeight - header.size().height) / 2))
        let arrows = arrowRects
        drawText(date.includesTime ? "Сейчас" : "Сегодня", in: arrows.today, size: 12, color: Palette.textSecondary, alignment: .right)
        drawText("‹", in: arrows.previous, size: 17, color: Palette.textSecondary, alignment: .center)
        drawText("›", in: arrows.next, size: 17, color: Palette.textSecondary, alignment: .center)

        for (column, title) in DatePickerMonth.weekdayTitles.enumerated() {
            let rect = NSRect(x: gridLeft + CGFloat(column) * Layout.cell, y: headerTop + Layout.headerHeight, width: Layout.cell,
                              height: Layout.weekdayHeight)
            drawText(title, in: rect, size: 11, color: Palette.textSecondary, alignment: .center)
        }
        let shown = date.shownComponents(in: calendar)
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        for (index, day) in shownMonth.days.enumerated() {
            let rect = dayRect(index)
            let isSelected = shown?.year == day.year && shown?.month == day.month && shown?.day == day.day
            let isToday = today.year == day.year && today.month == day.month && today.day == day.day
            if isSelected {
                Palette.checkboxChecked.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 4, yRadius: 4).fill()
            }
            // Сегодня, если не выбрано, — синими цифрами.
            let color: NSColor = isSelected ? .white : isToday ? Palette.checkboxChecked
                : day.isInMonth ? Palette.textPrimary : Palette.textSecondary
            drawText("\(day.day)", in: rect, size: 12, color: color, alignment: .center)
        }

        Palette.popupDivider.setFill()
        NSRect(x: card.minX, y: dividerY, width: card.width, height: 1).fill()
        drawRow(0, title: "Время", trailing: nil, toggle: date.includesTime)
        drawRow(1, title: "Напомнить", trailing: ReminderChoice.current(for: date).title, toggle: nil)
        if showsPermissionHint {
            drawText("Разрешите уведомления в Системных настройках", in: NSRect(x: card.minX + Layout.padding, y: rowRect(1).maxY,
                                                                                 width: card.width - 2 * Layout.padding, height: Layout.hintHeight),
                     size: 11, color: Palette.destructiveText, alignment: .left)
        }
        Palette.popupDivider.setFill()
        NSRect(x: card.minX, y: rowRect(2).minY - Layout.dividerGap - 1, width: card.width, height: 1).fill()
        drawRow(2, title: "Удалить", trailing: nil, toggle: nil)
    }

    private func drawRow(_ index: Int, title: String, trailing: String?, toggle: Bool?) {
        let rect = rowRect(index)
        drawText(title, in: rect.insetBy(dx: 8, dy: 0), size: 14, color: Palette.textPrimary, alignment: .left)
        if let toggle {
            // Переключатель Notion: 30 × 18, выключенный — серый.
            let track = NSRect(x: rect.maxX - 8 - 30, y: rect.midY - 9, width: 30, height: 18)
            (toggle ? Palette.checkboxChecked : Palette.textSecondary.withAlphaComponent(0.45)).setFill()
            NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9).fill()
            NSColor.white.setFill()
            let knob = NSRect(x: toggle ? track.maxX - 16 : track.minX + 2, y: track.minY + 2, width: 14, height: 14)
            NSBezierPath(ovalIn: knob).fill()
        }
        if let trailing {
            let chevron = NSRect(x: rect.maxX - 8 - 10, y: rect.minY, width: 10, height: rect.height)
            drawText("›", in: chevron, size: 15, color: Palette.textSecondary, alignment: .center)
            drawText(trailing, in: NSRect(x: rect.minX, y: rect.minY, width: chevron.minX - 4 - rect.minX, height: rect.height),
                     size: 13, color: Palette.textSecondary, alignment: .right)
        }
    }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor, alignment: NSTextAlignment) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color,
                                                                    .paragraphStyle: paragraph])
        let height = string.size().height
        string.draw(in: NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height))
    }

    // MARK: Правка

    private func updateFields() {
        dateField.stringValue = date.shownComponents(in: calendar).flatMap { parts in
            parts.year.map { DateMention.absoluteDayText(year: $0, month: parts.month ?? 1, day: parts.day ?? 1) }
        } ?? date.start
        timeField.stringValue = date.timeText(calendar: calendar) ?? ""
        needsLayout = true
    }

    private func commit(_ edited: DateMention) {
        date = edited
        updateFields()
        needsDisplay = true
        onChange?(edited)
    }

    /// День из сетки — в поясе даты (у даты без времени пояс не важен).
    func selectDay(at index: Int) {
        let day = shownMonth.days[index]
        if !day.isInMonth { shownMonth = DatePickerMonth(year: day.year, month: day.month) }
        commit(date.edited(day: DateComponents(year: day.year, month: day.month, day: day.day)))
    }

    func setIncludesTime(_ on: Bool) {
        let time = on ? (calendar.component(.hour, from: now) + 1) % 24 : 0
        commit(date.edited(includesTime: on, time: on ? (date.startComponents?.hour ?? time, 0) : nil))
    }

    func setReminder(_ choice: ReminderChoice) {
        let wasOff = date.reminder == nil
        commit(date.edited(reminder: choice))
        guard wasOff, choice != .none, let onReminderEnabled else { return }
        Task { @MainActor in
            let allowed = await onReminderEnabled()
            if showsPermissionHint == allowed {
                showsPermissionHint = !allowed
                resizeWindow()
            }
        }
    }

    private func resizeWindow() {
        guard let window else { return }
        let margin = PopupMenuWindow.shadowMargin
        var frame = window.frame
        let height = cardSize.height + 2 * margin
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let arrows = arrowRects
        if arrows.previous.contains(point) { shownMonth = shownMonth.previous; needsDisplay = true; return }
        if arrows.next.contains(point) { shownMonth = shownMonth.next; needsDisplay = true; return }
        if arrows.today.contains(point) {
            let today = calendar.dateComponents([.year, .month, .day], from: now)
            shownMonth = DatePickerMonth(year: today.year!, month: today.month!)
            commit(date.edited(day: today))
            return
        }
        if let index = (0..<42).first(where: { dayRect($0).contains(point) }) { selectDay(at: index); return }
        if rowRect(0).contains(point) { setIncludesTime(!date.includesTime); return }
        if rowRect(1).contains(point) { showReminderMenu(); return }
        if rowRect(2).contains(point) { onDelete?() }
    }

    @objc private func reminderRowPressed() { showReminderMenu() }

    private func showReminderMenu() {
        let menu = NSMenu()
        let current = ReminderChoice.current(for: date)
        for choice in ReminderChoice.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(reminderChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.title
            item.state = choice == current ? .on : .off
            menu.addItem(item)
        }
        isShowingMenu = true
        let row = rowRect(1)
        menu.popUp(positioning: nil, at: NSPoint(x: row.maxX - 120, y: row.maxY), in: self)
        isShowingMenu = false
    }

    @objc private func reminderChosen(_ item: NSMenuItem) {
        guard let choice = ReminderChoice.allCases.first(where: { $0.title == item.representedObject as? String }) else { return }
        setReminder(choice)
    }

    // MARK: Поля даты и времени

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === dateField, let parsed = DateQuery.parse(field.stringValue, now: now, calendar: calendar), let parts = parsed.startComponents {
            shownMonth = DatePickerMonth(year: parts.year!, month: parts.month!)
            commit(date.edited(day: parts))
        } else if field === timeField {
            let pieces = field.stringValue.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if pieces.count == 2, (0...23).contains(pieces[0]), (0...59).contains(pieces[1]) {
                commit(date.edited(includesTime: true, time: (pieces[0], pieces[1])))
            }
        }
        updateFields()
    }
}
