import AppKit
import NotesCore
import VisualStyle

extension DateMention {
    /// Та же дата (тот же id) с другим днём, временем или напоминанием; напоминание едет за датой по своему выбору.
    func edited(day: DateComponents? = nil, includesTime: Bool? = nil, time: (hour: Int, minute: Int)? = nil,
                reminder choice: ReminderChoice? = nil) -> DateMention {
        let keptChoice = choice ?? ReminderChoice.current(for: self)
        var result = self
        // Дату или время поправили руками: «сегодня» шаблона больше не про день создания копии.
        if day != nil || includesTime != nil || time != nil { result.templateRelative = nil }
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

