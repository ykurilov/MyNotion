import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: сводка")
struct RollupTests {
    let type = PropertyTypes.type(for: .rollup)
    let context = TypeFixture.context(.rollup)

    @Test("Итог — по своему типу: число, текст, дата, список")
    func byResult() {
        #expect(type.comparables(.number(42), in: context).sortNumber == 42)
        #expect(type.comparables(.string("Банк"), in: context).sortText == "банк")
        #expect(type.comparables(TypeFixture.date("2026-10-21"), in: context).sortNumber == TypeFixture.seconds("2026-10-21"))
        #expect(type.csvText(["Банк", "Ремонт"], in: context) == "Банк, Ремонт")
        #expect(type.calculations.contains(.showOriginal) && type.calculations.contains(.showUnique))
        #expect(!type.isEditable)
    }
}
