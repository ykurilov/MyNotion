import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: изменено")
struct LastEditedTimeTests {
    @Test("Значение из страницы: `PropertyValue.pageDate`")
    func fromPage() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let value = PropertyValue.pageDate(date, in: TypeFixture.context(.lastEditedTime))
        #expect(value["hasTime"] == .bool(true))
        #expect(PropertyTypes.type(for: .lastEditedTime).comparables(value, in: TypeFixture.context(.lastEditedTime)).sortNumber == 1_790_000_000)
    }
}
