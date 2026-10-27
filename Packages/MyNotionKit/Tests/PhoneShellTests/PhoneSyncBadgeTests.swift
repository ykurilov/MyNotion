import Foundation
import PhoneShell
import Testing

/// Подпись «когда синхронизировано последний раз» — по подменённым часам.
@Suite("iPhone: значок синхронизации")
struct PhoneSyncBadgeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return calendar
    }

    func text(secondsAgo: TimeInterval?) -> String {
        PhoneSyncBadge(kind: .ready, detail: "", lastSyncedAt: secondsAgo.map { now.addingTimeInterval(-$0) })
            .lastSyncedText(now: now, calendar: calendar)
    }

    @Test("Ещё ни разу")
    func never() { #expect(text(secondsAgo: nil) == "Ещё не синхронизировано") }

    @Test("Меньше минуты — «только что»")
    func justNow() { #expect(text(secondsAgo: 20) == "Синхронизировано только что") }

    @Test("Минуты — с правильным окончанием", arguments: [(1, "1 минуту"), (3, "3 минуты"), (5, "5 минут"), (11, "11 минут"), (21, "21 минуту")])
    func minutes(value: Int, words: String) {
        #expect(text(secondsAgo: TimeInterval(value * 60 + 5)) == "Синхронизировано \(words) назад")
    }

    @Test("Больше часа — время суток")
    func hours() {
        let earlier = now.addingTimeInterval(-3 * 3_600)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "H:mm"
        let expected = calendar.isDate(earlier, inSameDayAs: now) ? "Синхронизировано сегодня в \(formatter.string(from: earlier))"
                                                                   : "Синхронизировано вчера в \(formatter.string(from: earlier))"
        #expect(text(secondsAgo: 3 * 3_600) == expected)
    }

    @Test("Заголовки состояний")
    func titles() {
        #expect(PhoneSyncBadge(kind: .ready, detail: "").title == "Синхронизировано")
        #expect(PhoneSyncBadge(kind: .sending, detail: "").title == "Отправка…")
        #expect(PhoneSyncBadge(kind: .error, detail: "").title == "Ошибка синхронизации")
    }
}
