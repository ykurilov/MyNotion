import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: флажок")
struct CheckboxTests {
    let type = PropertyTypes.type(for: .checkbox)
    let context = TypeFixture.context(.checkbox)

    @Test("sortNumber 0/1; CSV «Yes»/«No»; разбор Yes, true, 1, да")
    func values() {
        #expect(type.comparables(.bool(true), in: context) == CellComparables(sortNumber: 1))
        #expect(type.comparables(.bool(false), in: context) == CellComparables(sortNumber: 0))
        #expect(type.csvText(.bool(true), in: context) == "Yes" && type.csvText(nil, in: context) == "No")
        for yes in ["Yes", "true", "1", "да"] { #expect(type.parseCSV(yes, in: context) == .value(.bool(true))) }
        #expect(type.parseCSV("No", in: context) == .value(.bool(false)))
    }

    @Test("Условие «равно»; группы «Отмечен» / «Не отмечен»; итоги флажка")
    func operatorsGroupsCalculations() {
        #expect(type.filterOperators == [.is])
        #expect(type.groupKeys(.bool(true), in: context, bucket: nil) == ["checked"])
        #expect(type.groupKeys(nil, in: context, bucket: nil) == ["unchecked"])
        #expect(type.calculations == Calculation.common + Calculation.checkbox)
    }
}
