import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Окно даты ячейки (T066, spec US2, сценарий 4; contracts/property-types.md, «Дата: форматы и напоминания»):
/// диапазон «Дата окончания», «Включить время», выбор дня в календаре с понедельника, ввод текстом, форматы, список
/// напоминаний по наличию времени, «Очистить».
@Suite("Свойство «Дата»: окно ячейки (US2)")
struct DatePropertyTests {
    let zone = "Europe/Moscow"
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = 2
        return calendar
    }

    func day(_ year: Int, _ month: Int, _ day: Int) -> DateParts { DateParts(year: year, month: month, day: day) }

    @Test("Новая дата — выбранный день без времени; JSON как data-model.md")
    func newValue() {
        let value = DateCellValue(day: day(2026, 10, 21), timeZone: zone)
        #expect(value.json == ["start": "2026-10-21", "hasTime": false, "timeZone": "Europe/Moscow"])
        #expect(DateCellValue(json: value.json) == value)
        #expect(DateCellValue(json: nil) == nil)
    }

    @Test("«Дата окончания»: включить — конец как начало, второй щелчок по календарю ставит конец; раньше начала — меняются местами")
    func range() {
        var value = DateCellValue(day: day(2026, 10, 21), timeZone: zone)
        value.setHasEnd(true)
        #expect(value.json["end"] == "2026-10-21")
        value.pick(day(2026, 10, 25), editingEnd: true)
        #expect(value.json["end"] == "2026-10-25")
        value.pick(day(2026, 10, 19), editingEnd: true)
        #expect(value.json["start"] == "2026-10-19")
        #expect(value.json["end"] == "2026-10-21")
        value.pick(day(2026, 10, 30), editingEnd: false)
        #expect(value.json["start"] == "2026-10-21", "начало позже конца — тоже меняются местами")
        #expect(value.json["end"] == "2026-10-30")
        value.setHasEnd(false)
        #expect(value.json["end"] == nil)
    }

    @Test("«Включить время»: 9:00 по умолчанию, время сохраняется при смене дня; выключить — время уходит")
    func includeTime() {
        var value = DateCellValue(day: day(2026, 10, 21), timeZone: zone)
        value.setHasTime(true)
        #expect(value.json["start"] == "2026-10-21T09:00")
        #expect(value.json["hasTime"] == true)
        value.setTime(hour: 15, minute: 15, forEnd: false)
        value.pick(day(2026, 10, 22), editingEnd: false)
        #expect(value.json["start"] == "2026-10-22T15:15")
        value.setHasEnd(true)
        #expect(value.json["end"] == "2026-10-22T15:15")
        value.setHasTime(false)
        #expect(value.json["start"] == "2026-10-22")
        #expect(value.json["end"] == "2026-10-22")
    }

    @Test("Ввод текстом: «21.10.2026», «21.10.2026 15:15», «October 21, 2026»; мусор — не принимается")
    func typedDate() {
        var value = DateCellValue(day: day(2026, 1, 1), timeZone: zone)
        let first = value.type("21.10.2026", forEnd: false)
        #expect(first)
        #expect(value.json["start"] == "2026-10-21")
        let second = value.type("21.10.2026 15:15", forEnd: false)
        #expect(second)
        #expect(value.json["start"] == "2026-10-21T15:15")
        #expect(value.json["hasTime"] == true)
        let third = value.type("October 22, 2026", forEnd: false)
        #expect(third)
        #expect(value.json["start"] == "2026-10-22T15:15", "без времени в тексте — время прежнее")
        let garbage = value.type("завтра в обед", forEnd: false)
        #expect(garbage == false)
    }

    @Test("Календарь — 6 недель с понедельника; октябрь 2026 начинается с 28 сентября")
    func monthGrid() {
        let days = MonthGrid.days(year: 2026, month: 10, calendar: calendar)
        #expect(days.count == 42)
        #expect(days.first == day(2026, 9, 28))
        #expect(days[3] == day(2026, 10, 1))
        #expect(days.last == day(2026, 11, 8))
        #expect(MonthGrid.weekdaySymbols(calendar: calendar, locale: Locale(identifier: "ru_RU")) == ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"])
        #expect(MonthGrid.title(year: 2026, month: 10, locale: Locale(identifier: "ru_RU")) == "Октябрь 2026")
    }

    @Test("Напоминания: без времени — день события и за 1, 2 дня, неделю (9:00); со временем — минуты, часы, дни")
    func reminderLists() {
        #expect(DateReminder.options(hasTime: false) == [.day0At9, .day1, .day2, .week1])
        #expect(DateReminder.options(hasTime: false).map { $0.title(hasTime: false) }
                == ["В день события (9:00)", "За 1 день (9:00)", "За 2 дня (9:00)", "За неделю (9:00)"])
        #expect(DateReminder.options(hasTime: true) == [.atTime, .minutes5, .minutes10, .minutes15, .minutes30, .hour1, .hour2, .day1, .day2])
        #expect(DateReminder.options(hasTime: true).map { $0.title(hasTime: true) }
                == ["В момент события", "За 5 минут", "За 10 минут", "За 15 минут", "За 30 минут", "За 1 час", "За 2 часа", "За 1 день", "За 2 дня"])
    }

    @Test("Смена «Включить время» переводит напоминание на ближайшее из нового списка")
    func reminderFollowsTime() {
        var value = DateCellValue(day: day(2026, 10, 21), timeZone: zone)
        value.reminder = .day0At9
        value.setHasTime(true)
        #expect(value.reminder == .atTime)
        value.reminder = .minutes30
        value.setHasTime(false)
        #expect(value.reminder == .day0At9)
        value.reminder = .week1
        value.setHasTime(true)
        #expect(value.reminder == .day2)
        value.reminder = .day1
        value.setHasTime(false)
        #expect(value.reminder == .day1)
        #expect(value.json["reminder"] == "day1")
        value.reminder = nil
        #expect(value.json["reminder"] == nil)
    }

    @Test("Форматы даты и времени — названия и порядок окна; показ по формату свойства")
    func formats() {
        #expect(DateDisplayFormat.allCases.map(\.title) == ["Полный", "Короткий", "Месяц/День/Год", "День/Месяц/Год", "Год/Месяц/День", "Относительный"])
        #expect(TimeDisplayFormat.allCases.map(\.title) == ["12 часов", "24 часа", "Скрыть"])
        let type = PropertyTypes.type(for: .date)
        let value: JSONValue = ["start": "2026-10-21T15:15", "end": "2026-10-23T09:00", "hasTime": true, "timeZone": "Europe/Moscow"]
        func shown(_ config: JSONValue) -> String {
            var calendar = calendar
            calendar.timeZone = TimeZone(identifier: zone)!
            let property = DatabaseProperty(databaseId: UUID(), name: "Срок", kind: .date, config: config, sortKey: .between(nil, nil))
            return type.displayText(value, in: PropertyContext(property: property, calendar: calendar, locale: Locale(identifier: "ru_RU")))
        }
        #expect(shown(["dateFormat": "dmy", "timeFormat": "h24"]) == "21/10/2026, 15:15 → 23/10/2026, 09:00")
        #expect(shown(["dateFormat": "ymd", "timeFormat": "hidden"]) == "2026/10/21 → 2026/10/23")
        #expect(shown(["dateFormat": "mdy", "timeFormat": "h12"]).hasPrefix("10/21/2026, 3:15"))
    }
}
