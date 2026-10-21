import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: ID")
struct UniqueIdTests {
    let type = PropertyTypes.type(for: .uniqueId)

    @Test("Номер; с префиксом — «ЗАД-12»; поиск — по номеру и с префиксом; разбор CSV")
    func values() {
        let context = TypeFixture.context(.uniqueId, ["prefix": "ЗАД"])
        #expect(type.comparables(.number(12), in: context) == CellComparables(sortNumber: 12, searchText: "зад-12 12"))
        #expect(type.displayText(.number(12), in: context) == "ЗАД-12")
        #expect(type.csvText(.number(12), in: context) == "ЗАД-12")
        #expect(type.displayText(.number(7), in: TypeFixture.context(.uniqueId)) == "7")
        #expect(type.parseCSV("ЗАД-12", in: context) == .value(.number(12)))
        #expect(type.filterOperators == PropertyTypes.type(for: .number).filterOperators.filter { $0 != .isEmpty && $0 != .isNotEmpty })
        #expect(!type.isGroupable && !type.isEditable)
    }
}
