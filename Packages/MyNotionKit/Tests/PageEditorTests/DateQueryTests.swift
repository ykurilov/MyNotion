import Foundation
import Testing
@testable import NotesCore
@testable import PageEditor

/// Даты по набору после «@» и их вид в тексте (contracts/blocks-and-keys.md, «Даты и напоминания»; tasks.md T054).
@Suite("Даты по набору")
struct DateQueryTests {
    /// Москва, 19 октября 2026, 15:00.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }()
    static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15))!

    func parsed(_ query: String) -> DateMention? {
        DateQuery.parse(query, now: Self.now, calendar: Self.calendar)
    }

    @Test("Слова: сегодня, завтра, вчера, через неделю — дата без времени в поясе Mac")
    func words() {
        #expect(parsed("сегодня")?.start == "2026-10-19")
        #expect(parsed("Завтра")?.start == "2026-10-20")
        #expect(parsed("вчера")?.start == "2026-10-18")
        #expect(parsed("через неделю")?.start == "2026-10-26")
        #expect(parsed("tomorrow")?.start == "2026-10-20")
        let today = parsed("сегодня")
        #expect(today?.includesTime == false)
        #expect(today?.timeZone == "Europe/Moscow")
        #expect(today?.reminder == nil)
    }

    @Test("Набранная дата: «25 окт», «25.10», «25.10.2026», «25 октября 14:30»")
    func typedDates() {
        #expect(parsed("25 окт")?.start == "2026-10-25")
        #expect(parsed("25 октября")?.start == "2026-10-25")
        #expect(parsed("25.10")?.start == "2026-10-25")
        #expect(parsed("25.10.2026")?.start == "2026-10-25")
        #expect(parsed("3.1.2027")?.start == "2027-01-03")
        let withTime = parsed("25 октября 14:30")
        #expect(withTime?.start == "2026-10-25T14:30")
        #expect(withTime?.includesTime == true)
        #expect(parsed("25.10.2026 9:05")?.start == "2026-10-25T09:05")
    }

    @Test("Не дата — пусто: несуществующий день, буквы, время без даты")
    func notDates() {
        #expect(parsed("31.02") == nil)
        #expect(parsed("Проект") == nil)
        #expect(parsed("25 окт 25:00") == nil)
        #expect(parsed("") == nil)
    }

    @Test("Подсказки окна «@»: без набора — четыре слова, по началу слова — подходящие, набранная дата — первой")
    func suggestions() {
        let titles = { (query: String) in
            DateQuery.suggestions(for: query, now: Self.now, calendar: Self.calendar).map(\.title)
        }
        #expect(titles("") == ["Сегодня", "Завтра", "Вчера", "Через неделю"])
        #expect(titles("за") == ["Завтра"])
        #expect(titles("через") == ["Через неделю"])
        #expect(titles("25.10") == ["25 октября 2026"])
        #expect(titles("25 октября 14:30") == ["25 октября 2026 14:30"])
        #expect(titles("Проект").isEmpty)
        // Каждая подсказка — новая дата со своим id.
        let ids = DateQuery.suggestions(for: "", now: Self.now, calendar: Self.calendar).map(\.mention.id)
        #expect(Set(ids).count == 4)
    }

    @Test("Вид в тексте: «@Сегодня», «@Завтра», иначе «@20 октября 2026»; время «9:00»")
    func shownText() {
        func date(_ start: String, time: Bool = false) -> DateMention {
            DateMention(start: start, includesTime: time, timeZone: "Europe/Moscow")
        }
        #expect(date("2026-10-19").shownText(now: Self.now, calendar: Self.calendar) == "@Сегодня")
        #expect(date("2026-10-20").shownText(now: Self.now, calendar: Self.calendar) == "@Завтра")
        #expect(date("2026-10-18").shownText(now: Self.now, calendar: Self.calendar) == "@Вчера")
        #expect(date("2026-10-21").shownText(now: Self.now, calendar: Self.calendar) == "@21 октября 2026")
        #expect(date("2026-10-20T09:00", time: true).shownText(now: Self.now, calendar: Self.calendar) == "@Завтра 9:00")
        #expect(date("2026-12-31T23:05", time: true).absoluteText(calendar: Self.calendar) == "31 декабря 2026, 23:05")
    }

    @Test("Часовой пояс: время — в поясе этого Mac; день без времени от пояса не зависит")
    func timeZones() {
        let bali = DateMention(start: "2026-10-20T09:00", includesTime: true, timeZone: "Asia/Makassar")
        #expect(bali.timeText(calendar: Self.calendar) == "4:00")
        #expect(bali.startDate == ISO8601DateFormatter().date(from: "2026-10-20T01:00:00Z"))
        let dayOnly = DateMention(start: "2026-10-20", includesTime: false, timeZone: "Asia/Makassar")
        #expect(dayOnly.absoluteText(calendar: Self.calendar) == "20 октября 2026")
    }

    @Test("«Напомнить»: в момент события, за 5 минут, за час, за день в 9:00; у дня без времени событие — в 9:00")
    func reminderChoices() throws {
        let iso = ISO8601DateFormatter()
        let meeting = DateMention(start: "2026-10-20T14:30", includesTime: true, timeZone: "Europe/Moscow")
        #expect(ReminderChoice.atEvent.fireAt(for: meeting) == iso.date(from: "2026-10-20T11:30:00Z"))
        #expect(ReminderChoice.fiveMinutesBefore.fireAt(for: meeting) == iso.date(from: "2026-10-20T11:25:00Z"))
        #expect(ReminderChoice.hourBefore.fireAt(for: meeting) == iso.date(from: "2026-10-20T10:30:00Z"))
        #expect(ReminderChoice.dayBefore.fireAt(for: meeting) == iso.date(from: "2026-10-19T06:00:00Z"))
        #expect(ReminderChoice.none.fireAt(for: meeting) == nil)

        let day = DateMention(start: "2026-10-20", includesTime: false, timeZone: "Europe/Moscow")
        #expect(ReminderChoice.atEvent.fireAt(for: day) == iso.date(from: "2026-10-20T06:00:00Z"))

        var reminded = meeting
        reminded.reminder = DateMention.Reminder(fireAt: try #require(ReminderChoice.hourBefore.fireAt(for: meeting)))
        #expect(ReminderChoice.current(for: reminded) == .hourBefore)
        #expect(ReminderChoice.current(for: meeting) == ReminderChoice.none)
    }

    @Test("Календарик: смена дня и времени — тот же id, напоминание едет за датой; время выключено — день без времени")
    func editingKeepsIdAndReminder() throws {
        let iso = ISO8601DateFormatter()
        var date = DateMention(start: "2026-10-20T14:30", includesTime: true, timeZone: "Europe/Moscow")
        date = date.edited(reminder: .hourBefore)
        #expect(date.reminder?.fireAt == iso.date(from: "2026-10-20T10:30:00Z"))
        let moved = date.edited(day: DateComponents(year: 2026, month: 10, day: 22), time: (16, 0))
        #expect(moved.id == date.id)
        #expect(moved.start == "2026-10-22T16:00")
        #expect(moved.reminder?.fireAt == iso.date(from: "2026-10-22T12:00:00Z"))
        let dayOnly = moved.edited(includesTime: false)
        #expect(dayOnly.start == "2026-10-22")
        #expect(dayOnly.includesTime == false)
        #expect(dayOnly.edited(reminder: ReminderChoice.none).reminder == nil)
    }
}

/// Сетка месяца календарика (как у Notion): 6 недель с понедельника, соседние месяцы серые.
@Suite("Календарик: сетка месяца")
struct DatePickerGridTests {
    @Test("Октябрь 2026: с понедельника 28 сентября, 42 дня, заголовок «Октябрь 2026»")
    func octoberGrid() {
        let grid = DatePickerMonth(year: 2026, month: 10)
        #expect(grid.title == "Октябрь 2026")
        #expect(grid.days.count == 42)
        #expect(grid.days.first?.month == 9 && grid.days.first?.day == 28)
        #expect(grid.days.filter(\.isInMonth).count == 31)
        #expect(grid.days[3].day == 1 && grid.days[3].isInMonth)
        #expect(DatePickerMonth.weekdayTitles == ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"])
    }

    @Test("Стрелки листают через год")
    func paging() {
        #expect(DatePickerMonth(year: 2026, month: 12).next.title == "Январь 2027")
        #expect(DatePickerMonth(year: 2026, month: 1).previous.title == "Декабрь 2025")
    }
}
