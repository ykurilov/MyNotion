import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: выбор")
struct SelectTests {
    let type = PropertyTypes.type(for: .select)
    let context = TypeFixture.context(.select, options: TypeFixture.options)

    @Test("Значение — id варианта; sortText — id (фильтр по индексу), sortNumber — место в списке, поиск — название")
    func comparables() {
        let high = TypeFixture.options[2]
        #expect(type.comparables(TypeFixture.id(high), in: context)
                == CellComparables(sortText: high.id.uuidString.lowercased(), sortNumber: 2, searchText: "высокий"))
        #expect(type.comparables(.string(UUID().uuidString), in: context) == CellComparables(), "удалённый вариант — пусто")
    }

    @Test("Показ и CSV — название; разбор CSV — вариант по названию или новый")
    func textAndCSV() {
        #expect(type.displayText(TypeFixture.id(TypeFixture.options[1]), in: context) == "Средний")
        #expect(type.csvText(TypeFixture.id(TypeFixture.options[1]), in: context) == "Средний")
        #expect(type.parseCSV("Средний", in: context) == .value(TypeFixture.id(TypeFixture.options[1])))
        #expect(type.parseCSV("Новый", in: context) == .options(["Новый"]))
    }

    @Test("Условия, группы по вариантам, итоги")
    func operatorsGroupsCalculations() {
        #expect(type.filterOperators == [.is, .isNot, .isEmpty, .isNotEmpty])
        #expect(type.groupKeys(TypeFixture.id(TypeFixture.options[0]), in: context, bucket: nil) == [TypeFixture.options[0].id.uuidString.lowercased()])
        #expect(type.calculations == Calculation.common)
    }
}
