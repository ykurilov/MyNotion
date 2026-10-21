import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Типы: создано и изменено")
struct CreatedTimeTests {
    @Test("Значение — дата-время страницы; CSV — дата со временем как у Notion; условия дат; правки нет")
    func pageTimes() {
        for kind in [PropertyKind.createdTime, .lastEditedTime] {
            let type = PropertyTypes.type(for: kind)
            let context = TypeFixture.context(kind)
            let value = TypeFixture.date("2026-10-21T09:05", hasTime: true)
            #expect(type.csvText(value, in: context) == "October 21, 2026 9:05 AM")
            #expect(type.comparables(value, in: context).sortNumber == TypeFixture.seconds("2026-10-21T09:05"))
            #expect(type.filterOperators == PropertyTypes.type(for: .date).filterOperators)
            #expect(!type.isEditable)
        }
    }
}
