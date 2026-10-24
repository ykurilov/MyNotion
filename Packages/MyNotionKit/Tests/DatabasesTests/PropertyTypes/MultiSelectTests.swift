import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: множественный выбор")
struct MultiSelectTests {
    let type = PropertyTypes.type(for: .multiSelect)
    let context = TypeFixture.context(.multiSelect, options: TypeFixture.options)
    var both: JSONValue { [TypeFixture.id(TypeFixture.options[2]), TypeFixture.id(TypeFixture.options[0])] }

    @Test("sortText — id через пробел (фильтр «содержит»), sortNumber — место первого, поиск — названия")
    func comparables() {
        let ids = [TypeFixture.options[2], TypeFixture.options[0]].map { $0.id.uuidString.lowercased() }
        #expect(type.comparables(both, in: context) == CellComparables(sortText: ids.joined(separator: " "), sortNumber: 2, searchText: "высокий низкий"))
        #expect(type.comparables([], in: context) == CellComparables())
    }

    @Test("Показ и CSV — названия через «, »; разбор — по названиям, неизвестные — новые варианты")
    func textAndCSV() {
        #expect(type.csvText(both, in: context) == "Высокий, Низкий")
        #expect(type.parseCSV("Высокий, Низкий", in: context) == .value(both))
        #expect(type.parseCSV("Высокий, Ещё", in: context) == .options(["Высокий", "Ещё"]))
    }

    @Test("Условия «содержит»; строка — в группе каждого своего варианта")
    func operatorsGroups() {
        #expect(type.filterOperators == [.contains, .doesNotContain, .isEmpty, .isNotEmpty])
        #expect(type.groupKeys(both, in: context, bucket: nil).count == 2)
    }
}
