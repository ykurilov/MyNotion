import AppKit
import NotesCore
import VisualStyle

extension DateMention {
    /// Та же дата (тот же id) с другим днём, временем или напоминанием; напоминание едет за датой по своему выбору.
    func edited(day: DateComponents? = nil, includesTime: Bool? = nil, time: (hour: Int, minute: Int)? = nil,
                reminder choice: ReminderChoice? = nil) -> DateMention {
        let keptChoice = choice ?? ReminderChoice.current(for: self)
        var result = self
        var components = startComponents ?? DateComponents()
        if let day {
            components.year = day.year
            components.month = day.month
            components.day = day.day
        }
        result.includesTime = includesTime ?? self.includesTime
        if result.includesTime {
            if let time {
                components.hour = time.hour
                components.minute = time.minute
            }
            components.hour = components.hour ?? ReminderChoice.dayStartHour
            components.minute = components.minute ?? 0
        }
        result.start = DateMention.startText(year: components.year ?? 2000, month: components.month ?? 1, day: components.day ?? 1,
                                             hour: result.includesTime ? components.hour : nil,
                                             minute: result.includesTime ? components.minute : nil)
        result.reminder = keptChoice.fireAt(for: result).map(DateMention.Reminder.init(fireAt:))
        return result
    }
}

/// Календарик даты (contracts/blocks-and-keys.md, «Даты и напоминания»): месяц, время (вкл/выкл), «Напомнить»
/// и «Удалить». Каждая правка сразу меняет дату в тексте одним шагом ⌘Z; id даты — тот же.
@MainActor
final class DatePickerPopoverController: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?
    private weak var textView: PageTextView?
    private(set) var dateId: UUID?
    private var form: DatePickerForm?

    var isOpen: Bool { popover?.isShown == true }

    func open(for date: DateMention, atCharacter index: Int, in textView: PageTextView) {
        close()
        self.textView = textView
        dateId = date.id
        let form = DatePickerForm(date: date, calendar: textView.calendar)
        form.onChange = { [weak self] edited in self?.apply(edited) }
        form.onReminderEnabled = { [weak self] in await self?.requestPermission() ?? true }
        form.onDelete = { [weak self] in
            self?.textView?.replaceDate(date.id, with: nil)
            self?.close()
        }
        self.form = form
        let controller = NSViewController()
        controller.view = form
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = self
        self.popover = popover
        let rect = textView.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        guard let window = textView.window, window.isVisible else { return }
        let local = textView.convert(window.convertFromScreen(rect), from: nil)
        popover.show(relativeTo: local, of: textView, preferredEdge: .maxY)
    }

    func close() {
        popover?.performClose(nil)
        popover = nil
        form = nil
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            popover = nil
            form = nil
        }
    }

    private func apply(_ edited: DateMention) {
        textView?.replaceDate(edited.id, with: edited)
    }

    private func requestPermission() async -> Bool {
        guard let request = textView?.onRequestReminderPermission else { return true }
        return await request()
    }
}

extension PageTextView {
    /// Заменить дату `id` в тексте на `date` (тот же id) или стереть (`nil`).
    func replaceDate(_ id: UUID, with date: DateMention?) {
        guard let textStorage else { return }
        var found: Int?
        textStorage.enumerateAttribute(.inlineAtom, in: NSRange(location: 0, length: textStorage.length)) { value, range, stop in
            if case .date(let existing)? = value as? InlineStyle, existing.id == id {
                found = range.location
                stop.pointee = true
            }
        }
        guard let location = found, let position = mapper.blockPosition(at: location) else { return }
        let range = NSRange(location: location, length: 1)
        if let date {
            let selection = selectedRanges
            insertAtom(.date(date), in: range, blockAt: position.index)
            selectedRanges = selection
        } else {
            breakUndoCoalescing()
            replaceText(in: range, with: "")
        }
    }
}

/// Содержимое календарика.
@MainActor
final class DatePickerForm: NSView {
    private(set) var date: DateMention
    private let calendar: Calendar
    var onChange: ((DateMention) -> Void)?
    /// Включили «Напомнить» впервые: спросить разрешение; `false` — показать подсказку.
    var onReminderEnabled: (() async -> Bool)?
    var onDelete: (() -> Void)?

    private let dayPicker = NSDatePicker()
    private let timeToggle = NSButton(checkboxWithTitle: "Время", target: nil, action: nil)
    private let timePicker = NSDatePicker()
    private let reminderPopUp = NSPopUpButton()
    private let permissionHint = NSTextField(wrappingLabelWithString: "Разрешите уведомления в Системных настройках")
    private let deleteButton = NSButton(title: "Удалить", target: nil, action: nil)

    static let width: CGFloat = 260

    init(date: DateMention, calendar: Calendar) {
        self.date = date
        self.calendar = calendar
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 10))
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private func build() {
        var shownCalendar = calendar
        if let zone = TimeZone(identifier: date.timeZone), !date.includesTime { shownCalendar.timeZone = zone }
        for picker in [dayPicker, timePicker] {
            picker.calendar = shownCalendar
            picker.timeZone = shownCalendar.timeZone
            picker.locale = Locale(identifier: "ru_RU")
            picker.target = self
        }
        let moment = date.startDate ?? Date()
        dayPicker.datePickerStyle = .clockAndCalendar
        dayPicker.datePickerElements = .yearMonthDay
        dayPicker.dateValue = moment
        dayPicker.action = #selector(dayChanged)
        dayPicker.setAccessibilityIdentifier("date-picker-calendar")

        timeToggle.state = date.includesTime ? .on : .off
        timeToggle.target = self
        timeToggle.action = #selector(timeToggled)
        timeToggle.setAccessibilityIdentifier("date-picker-time-toggle")
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        timePicker.dateValue = moment
        timePicker.isEnabled = date.includesTime
        timePicker.action = #selector(timeChanged)
        timePicker.setAccessibilityIdentifier("date-picker-time")

        let reminderLabel = NSTextField(labelWithString: "Напомнить")
        reminderLabel.textColor = Palette.textSecondary
        reminderPopUp.addItems(withTitles: ReminderChoice.allCases.map(\.title))
        reminderPopUp.selectItem(at: ReminderChoice.allCases.firstIndex(of: .current(for: date)) ?? 0)
        reminderPopUp.target = self
        reminderPopUp.action = #selector(reminderChanged)
        reminderPopUp.setAccessibilityIdentifier("date-picker-reminder")

        permissionHint.textColor = Palette.destructiveText
        permissionHint.font = Typography.popupMenuShortcut.font
        permissionHint.isHidden = true
        permissionHint.setAccessibilityIdentifier("date-picker-permission-hint")

        deleteButton.bezelStyle = .inline
        deleteButton.contentTintColor = Palette.destructiveText
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.setAccessibilityIdentifier("date-picker-delete")

        let timeRow = NSStackView(views: [timeToggle, timePicker])
        let reminderRow = NSStackView(views: [reminderLabel, reminderPopUp])
        let stack = NSStackView(views: [dayPicker, timeRow, reminderRow, permissionHint, deleteButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            permissionHint.widthAnchor.constraint(equalToConstant: Self.width - 24),
        ])
        setAccessibilityIdentifier("date-picker")
    }

    private func commit(_ edited: DateMention) {
        date = edited
        onChange?(edited)
    }

    @objc private func dayChanged() {
        commit(date.edited(day: dayPicker.calendar?.dateComponents([.year, .month, .day], from: dayPicker.dateValue)))
    }

    @objc private func timeToggled() {
        let on = timeToggle.state == .on
        timePicker.isEnabled = on
        let parts = calendar.dateComponents([.hour, .minute], from: timePicker.dateValue)
        commit(date.edited(includesTime: on, time: on ? (parts.hour ?? 9, parts.minute ?? 0) : nil))
    }

    @objc private func timeChanged() {
        let parts = calendar.dateComponents([.hour, .minute], from: timePicker.dateValue)
        commit(date.edited(includesTime: true, time: (parts.hour ?? 9, parts.minute ?? 0)))
    }

    @objc private func reminderChanged() {
        let choice = ReminderChoice.allCases[max(0, reminderPopUp.indexOfSelectedItem)]
        let wasOff = date.reminder == nil
        commit(date.edited(reminder: choice))
        guard wasOff, choice != .none, let onReminderEnabled else { return }
        Task { @MainActor in
            let allowed = await onReminderEnabled()
            permissionHint.isHidden = allowed
        }
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}
