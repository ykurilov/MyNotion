import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: формула")
struct FormulaTests {
    let type = PropertyTypes.type(for: .formula)
    let context = TypeFixture.context(.formula)

    @Test("Итог — по типу: число, текст, флажок, дата; CSV — итог текстом")
    func byResult() {
        #expect(type.comparables(.bool(true), in: context).sortNumber == 1)
        #expect(type.csvText(.number(3), in: context) == "3")
        #expect(type.csvText(.bool(true), in: context) == "Yes")
        #expect(type.csvText(TypeFixture.date("2026-10-21"), in: context) == "October 21, 2026")
        #expect(!type.isEditable)
    }
}
