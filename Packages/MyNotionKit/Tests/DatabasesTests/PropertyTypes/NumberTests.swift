import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: число")
struct NumberTests {
    let type = PropertyTypes.type(for: .number)

    @Test("Сравнимое — само число; пустые — без колонок")
    func comparables() {
        let context = TypeFixture.context(.number)
        #expect(type.comparables(.number(-2.5), in: context) == CellComparables(sortNumber: -2.5, searchText: "-2.5"))
    }

    @Test("Показ по формату: число, с разделителями, процент, доллар, знаки после запятой")
    func display() {
        let en = Locale(identifier: "en_US")
        #expect(type.displayText(.number(1234.5), in: TypeFixture.context(.number, ["format": "number"], locale: en)) == "1234.5")
        #expect(type.displayText(.number(1234.5), in: TypeFixture.context(.number, ["format": "numberWithSeparators"], locale: en)) == "1,234.5")
        #expect(type.displayText(.number(0.125), in: TypeFixture.context(.number, ["format": "percent"], locale: en)) == "12.5%")
        #expect(type.displayText(.number(1234.5), in: TypeFixture.context(.number, ["format": "dollar"], locale: en)) == "$1,234.50")
        #expect(type.displayText(.number(2), in: TypeFixture.context(.number, ["format": "number", "decimals": 2], locale: en)) == "2.00")
    }

    @Test("CSV: без разделителей, точка; процент — «12%»; валюта — число. Разбор — с точкой, запятой и %")
    func csv() {
        let context = TypeFixture.context(.number, ["format": "percent"])
        #expect(type.csvText(.number(1234.5), in: TypeFixture.context(.number, ["format": "numberWithSeparators"])) == "1234.5")
        #expect(type.csvText(.number(0.12), in: context) == "12%")
        #expect(type.csvText(.number(10), in: TypeFixture.context(.number, ["format": "euro"])) == "10")
        #expect(type.parseCSV("1234.5", in: TypeFixture.context(.number)) == .value(.number(1234.5)))
        #expect(type.parseCSV("12%", in: TypeFixture.context(.number)) == .value(.number(0.12)))
        #expect(type.parseCSV("3,5", in: TypeFixture.context(.number)) == .value(.number(3.5)))
        #expect(type.parseCSV("abc", in: TypeFixture.context(.number)) == .value(nil))
    }

    @Test("Условия — сравнения; группы — диапазоны «от, до, шаг»; итоги — общие и числовые")
    func operatorsGroupsCalculations() {
        let context = TypeFixture.context(.number)
        #expect(type.filterOperators == [.equals, .notEquals, .greaterThan, .lessThan, .greaterThanOrEqual, .lessThanOrEqual, .isEmpty, .isNotEmpty])
        #expect(type.groupKeys(.number(17), in: context, bucket: ["from": 0, "to": 100, "step": 10]) == ["10-20"])
        #expect(type.groupKeys(.number(250), in: context, bucket: ["from": 0, "to": 100, "step": 10]) == ["100+"])
        #expect(type.calculations == Calculation.common + Calculation.numeric)
    }
}
