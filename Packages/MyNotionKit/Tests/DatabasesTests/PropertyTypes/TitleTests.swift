import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: название")
struct TitleTests {
    let type = PropertyTypes.type(for: .title)
    let context = TypeFixture.context(.title)

    @Test("Значение — название страницы; сравнимое и показ — как у текста; «Без названия» только в показе")
    func titleBehavesLikeText() {
        #expect(type.comparables("Позвонить в Банк", in: context) == CellComparables(sortText: "позвонить в банк", searchText: "позвонить в банк"))
        #expect(type.displayText("", in: context) == "Без названия")
        #expect(type.csvText("Позвонить", in: context) == "Позвонить")
        #expect(type.parseCSV("Позвонить", in: context) == .value("Позвонить"))
        #expect(type.filterOperators == PropertyTypes.type(for: .text).filterOperators)
    }
}
