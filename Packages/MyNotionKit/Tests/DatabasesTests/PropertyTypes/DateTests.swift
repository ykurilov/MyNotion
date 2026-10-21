import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: дата")
struct DateTests {
    let type = PropertyTypes.type(for: .date)
    let context = TypeFixture.context(.date)

    @Test("sortNumber — начало в секундах (в поясе значения); пустое — без колонок")
    func comparables() {
        #expect(type.comparables(TypeFixture.date("2026-10-21"), in: context).sortNumber == TypeFixture.seconds("2026-10-21"))
        #expect(type.comparables(TypeFixture.date("2026-10-21T15:15", hasTime: true), in: context).sortNumber == TypeFixture.seconds("2026-10-21T15:15"))
    }

    @Test("Показ «Полный» на языке macOS; время 24 часа; диапазон через «→»")
    func display() {
        #expect(type.displayText(TypeFixture.date("2026-10-21"), in: context) == "21 октября 2026 г.")
        #expect(type.displayText(TypeFixture.date("2026-10-21T15:15", hasTime: true), in: TypeFixture.context(.date, ["timeFormat": "h24"]))
                == "21 октября 2026 г., 15:15")
        #expect(type.displayText(TypeFixture.date("2026-10-21", end: "2026-10-23"), in: context) == "21 октября 2026 г. → 23 октября 2026 г.")
    }

    @Test("CSV как у Notion: «October 21, 2026», «October 21, 2026 3:15 PM», диапазон «… → …»; разбор — Notion и ISO")
    func csv() {
        #expect(type.csvText(TypeFixture.date("2026-10-21"), in: context) == "October 21, 2026")
        #expect(type.csvText(TypeFixture.date("2026-10-21T15:15", hasTime: true), in: context) == "October 21, 2026 3:15 PM")
        #expect(type.csvText(TypeFixture.date("2026-10-21", end: "2026-10-23"), in: context) == "October 21, 2026 → October 23, 2026")
        #expect(type.parseCSV("October 21, 2026", in: context) == .value(TypeFixture.date("2026-10-21")))
        #expect(type.parseCSV("October 21, 2026 3:15 PM", in: context) == .value(TypeFixture.date("2026-10-21T15:15", hasTime: true)))
        #expect(type.parseCSV("2026-10-21", in: context) == .value(TypeFixture.date("2026-10-21")))
        #expect(type.parseCSV("вчера", in: context) == .value(nil))
    }

    @Test("Условия дат; группы — день, неделя, месяц, год; итоги — общие и даты")
    func operatorsGroupsCalculations() {
        #expect(type.filterOperators == [.is, .isBefore, .isAfter, .isOnOrBefore, .isOnOrAfter, .isBetween, .isRelativeToToday, .isEmpty, .isNotEmpty])
        let value = TypeFixture.date("2026-10-21")
        #expect(type.groupKeys(value, in: context, bucket: "day") == ["2026-10-21"])
        #expect(type.groupKeys(value, in: context, bucket: "week") == ["2026-W43"])
        #expect(type.groupKeys(value, in: context, bucket: "month") == ["2026-10"])
        #expect(type.groupKeys(value, in: context, bucket: "year") == ["2026"])
        #expect(type.calculations == Calculation.common + Calculation.dates)
    }
}
