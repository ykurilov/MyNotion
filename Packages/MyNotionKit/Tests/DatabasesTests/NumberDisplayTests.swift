import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// «Число» в окне свойства (T073, spec US2, сценарий 6): форматы по порядку Notion с кодами валют, знаки после запятой,
/// «Показывать как» — полоса и кольцо с цветом, «Разделить на» и «Показывать число»; все ячейки колонки — в этом виде.
@Suite("Свойство «Число»: формат и «Показывать как» (US2)")
struct NumberDisplayTests {
    @Test("Форматы: число, с разделителями, процент, затем 38 валют по порядку Notion, у валют — код")
    func formats() {
        let formats = NumberDisplay.formats
        #expect(formats.prefix(5).map(\.id) == ["number", "numberWithSeparators", "percent", "dollar", "australianDollar"])
        #expect(formats.count == 41)
        #expect(formats.first { $0.id == "ruble" }?.code == "RUB")
        #expect(formats.last?.id == "peruvianSol")
        #expect(Set(formats.dropFirst(3).map(\.id)) == Set(NumberType.currencies.keys))
        #expect(NumberDisplay.decimalChoices.map(NumberDisplay.decimalsTitle) == ["По умолчанию", "0", "1", "2", "3", "4", "5", "6", "7", "8"])
    }

    @Test("Полоса: доля — число / «Разделить на» в пределах 0…1; кольцо; без числа — текста нет")
    func meter() {
        let bar: JSONValue = ["showAs": ["style": "bar", "color": "blue", "divideBy": 200, "showNumber": true]]
        #expect(NumberDisplay.meter(50, text: "50", config: bar) == CellPresentation.NumberMeter(fraction: 0.25, color: .blue, isRing: false, text: "50"))
        #expect(NumberDisplay.meter(500, text: "500", config: bar)?.fraction == 1)
        #expect(NumberDisplay.meter(-5, text: "-5", config: bar)?.fraction == 0)
        let ring: JSONValue = ["showAs": ["style": "ring", "color": "red", "divideBy": 10, "showNumber": false]]
        #expect(NumberDisplay.meter(5, text: "5", config: ring) == CellPresentation.NumberMeter(fraction: 0.5, color: .red, isRing: true, text: nil))
        #expect(NumberDisplay.meter(5, text: "5", config: .emptyObject) == nil)
    }

    @Test("Выбор вида: полоса по умолчанию — зелёная, «Разделить на 100», число видно; «Число» убирает настройку")
    func chooseStyle() {
        #expect(NumberDisplay.showAs(.bar, keeping: .emptyObject) == ["style": "bar", "color": "green", "divideBy": 100, "showNumber": true])
        let ring = NumberDisplay.showAs(.ring, keeping: ["showAs": ["style": "bar", "color": "pink", "divideBy": 5, "showNumber": false]])
        #expect(ring == ["style": "ring", "color": "pink", "divideBy": 5, "showNumber": false])
        #expect(NumberDisplay.showAs(.number, keeping: .emptyObject) == nil)
    }

    @Test("Ячейка числа с полосой — `meter`, без — текст по формату")
    func presentation() {
        let property = DatabaseProperty(databaseId: UUID(), name: "Готовность", kind: .number,
                                        config: ["format": "percent", "showAs": ["style": "bar", "color": "green", "divideBy": 1, "showNumber": true]],
                                        sortKey: .between(nil, nil))
        let row = RowSnapshot(id: UUID(), title: "", icon: nil, createdAt: Date(), updatedAt: Date(), cells: [property.id: 0.4], computed: [:], relations: [:])
        let context = PropertyContext(property: property, locale: Locale(identifier: "en_US"))
        #expect(CellPresenter.present(property, in: row, context: context) == .meter(.init(fraction: 0.4, color: .green, isRing: false, text: "40%")))
        var plain = property
        plain.config = ["format": "percent"]
        #expect(CellPresenter.present(plain, in: row, context: PropertyContext(property: plain, locale: Locale(identifier: "en_US"))) == .text("40%"))
    }
    @Test("Числовая сводка: формат и знаки, полоса/кольцо, проценты и возврат к числу")
    func rollupPresentation() {
        var property = DatabaseProperty(databaseId: UUID(), name: "Часов", kind: .rollup,
                                        config: ["calculation": "sum", "numberFormat": ["decimals": 2,
                                                "showAs": ["style": "bar", "divideBy": 10, "color": "blue", "showNumber": true]]],
                                        sortKey: .between(nil, nil))
        let row = RowSnapshot(id: UUID(), title: "", icon: nil, createdAt: Date(), updatedAt: Date(), cells: [:],
                              computed: [property.id: 2.5], relations: [:])
        func present() -> CellPresentation {
            CellPresenter.present(property, in: row, context: PropertyContext(property: property, locale: Locale(identifier: "en_US")))
        }
        #expect(present() == .meter(.init(fraction: 0.25, color: .blue, isRing: false, text: "2.50")))
        property.config["numberFormat"]?["showAs"]?["style"] = "ring"
        property.config["numberFormat"]?["showAs"]?["showNumber"] = false
        #expect(present() == .meter(.init(fraction: 0.25, color: .blue, isRing: true, text: nil)))
        property.config["numberFormat"]?["showAs"] = nil
        #expect(present() == .text("2.50"))
        property.config = ["calculation": "percentChecked", "numberFormat": ["decimals": 1]]
        #expect(present() == .text("250.0%"))
        property.config["numberFormat"]?["format"] = "number"
        #expect(present() == .text("2.5"))
    }

}
