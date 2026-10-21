import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: связь")
struct RelationTests {
    let type = PropertyTypes.type(for: .relation)
    let context = TypeFixture.context(.relation)
    let value: JSONValue = [["id": "0193a1b2-0000-7000-8000-0000000000a1", "title": "Банк", "path": "Задачи/Банк.md"],
                            ["id": "0193a1b2-0000-7000-8000-0000000000a2", "title": "Ремонт"]]

    @Test("Сортировка — по названию первой связанной строки; CSV — «Название (путь)» через «, »")
    func values() {
        #expect(type.comparables(value, in: context).sortText == "банк")
        #expect(type.csvText(value, in: context) == "Банк (Задачи/Банк.md), Ремонт")
        #expect(type.displayText(value, in: context) == "Банк, Ремонт")
    }

    @Test("Условия «содержит»; группы — по связанным строкам")
    func operators() {
        #expect(type.filterOperators == [.contains, .doesNotContain, .isEmpty, .isNotEmpty])
        #expect(type.groupKeys(value, in: context, bucket: nil) == ["0193a1b2-0000-7000-8000-0000000000a1", "0193a1b2-0000-7000-8000-0000000000a2"])
    }
}
