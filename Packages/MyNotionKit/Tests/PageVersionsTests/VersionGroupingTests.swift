import Foundation
import Testing
@testable import PageVersions

/// Группировка списка истории (spec, US6, сценарий 2): «1 минута / 15 минут / 1 час» — в каждом отрезке видна последняя
/// версия; текущая (самая новая) — всегда первой строкой.
@Suite("Версии: группировка списка")
struct VersionGroupingTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Makassar")!
        return calendar
    }

    private func version(_ hour: Int, _ minute: Int, _ second: Int = 0) -> PageVersionInfo {
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: hour, minute: minute, second: second))!
        return PageVersionInfo(id: .timeOrdered(), pageId: UUID(), createdAt: date, deviceName: "Mac", summary: VersionSummary(), byteCount: 1)
    }

    @Test("Каждый шаг объединяет версии своего отрезка; строка — последняя версия отрезка")
    func steps() {
        let versions = [version(18, 25, 40), version(18, 25, 5), version(18, 24), version(18, 16), version(18, 14), version(17, 59)]
        #expect(VersionGrouping.minute.group(versions, calendar: calendar).map(\.id) == [0, 2, 3, 4, 5].map { versions[$0].id })
        #expect(VersionGrouping.quarterHour.group(versions, calendar: calendar).map(\.id) == [0, 4, 5].map { versions[$0].id })
        #expect(VersionGrouping.hour.group(versions, calendar: calendar).map(\.id) == [0, 5].map { versions[$0].id })
    }

    @Test("Подписи пунктов как в Notion: «1 минута», «15 минут», «1 час»; на кнопке — коротко")
    func titles() {
        #expect(VersionGrouping.allCases.map(\.title) == ["1 минута", "15 минут", "1 час"])
        #expect(VersionGrouping.allCases.map(\.shortTitle) == ["1 мин", "15 мин", "1 ч"])
    }
}

@Suite("Версии: время в списке")
struct VersionTimeTextTests {
    @Test("Сегодня, вчера, дата, прошлый год")
    func texts() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Makassar")!
        func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
        }
        let now = at(2026, 10, 21, 18, 30)
        #expect(VersionTimeText.text(for: at(2026, 10, 21, 18, 25), now: now, calendar: calendar) == "Сегодня в 18:25")
        #expect(VersionTimeText.text(for: at(2026, 10, 20, 9, 5), now: now, calendar: calendar) == "Вчера в 9:05")
        #expect(VersionTimeText.text(for: at(2026, 10, 19, 18, 25), now: now, calendar: calendar) == "19 октября в 18:25")
        #expect(VersionTimeText.text(for: at(2025, 12, 31, 23, 59), now: now, calendar: calendar) == "31 декабря 2025 в 23:59")
    }
}
