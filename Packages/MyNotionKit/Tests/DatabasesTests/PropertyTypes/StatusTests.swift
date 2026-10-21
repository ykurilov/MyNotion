import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: статус")
struct StatusTests {
    let type = PropertyTypes.type(for: .status)
    let options: [SelectOption] = [("Готово", StatusGroup.complete), ("Не начато", .todo), ("В работе", .inProgress)].enumerated().map { index, item in
        SelectOption(propertyId: TypeFixture.property(.status).id, name: item.0, sortKey: FractionalSortKey(rawValue: ["a", "b", "c"][index])!,
                     statusGroup: item.1)
    }

    @Test("Порядок — по группам «К выполнению», «В работе», «Завершено», затем по месту")
    func orderByGroup() {
        let context = TypeFixture.context(.status, options: options)
        #expect(type.comparables(.string(options[0].id.uuidString.lowercased()), in: context).sortNumber == 2)
        #expect(type.comparables(.string(options[1].id.uuidString.lowercased()), in: context).sortNumber == 0)
        #expect(type.displayText(.string(options[2].id.uuidString.lowercased()), in: context) == "В работе")
    }

    @Test("Условия — как у выбора и «в группе»; разбор CSV — новые варианты")
    func operators() {
        #expect(type.filterOperators == [.is, .isNot, .isInGroup, .isEmpty, .isNotEmpty])
        #expect(type.parseCSV("Отложено", in: TypeFixture.context(.status, options: options)) == .options(["Отложено"]))
    }
}
