import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: текст")
struct TextTests {
    let type = PropertyTypes.type(for: .text)
    let context = TypeFixture.context(.text)

    @Test("Значение — InlineText; сравнимое — нижний регистр без диакритики, «ё» как «е»; пустое — без колонок")
    func comparables() {
        let columns = type.comparables(TypeFixture.text("Ёлка Café"), in: context)
        #expect(columns.sortText == "елка cafe" && columns.searchText == "елка cafe" && columns.sortNumber == nil)
        #expect(type.comparables(TypeFixture.text(""), in: context) == CellComparables())
    }

    @Test("Показ и CSV — текст как есть; разбор CSV — InlineText")
    func textAndCSV() {
        #expect(type.displayText(TypeFixture.text("Банк, «срочно»"), in: context) == "Банк, «срочно»")
        #expect(type.csvText(TypeFixture.text("a\nb"), in: context) == "a\nb")
        #expect(type.csvText(nil, in: context) == "")
        #expect(type.parseCSV("Банк", in: context) == .value(TypeFixture.text("Банк")))
        #expect(type.parseCSV("", in: context) == .value(nil))
    }

    @Test("Условия, группы — точное значение, итоги — общие")
    func operatorsGroupsCalculations() {
        #expect(type.filterOperators == [.is, .isNot, .contains, .doesNotContain, .startsWith, .endsWith, .isEmpty, .isNotEmpty])
        #expect(type.groupKeys(TypeFixture.text("Банк"), in: context, bucket: nil) == ["банк"])
        #expect(type.groupKeys(nil, in: context, bucket: nil).isEmpty)
        #expect(type.calculations == Calculation.common)
    }
}
