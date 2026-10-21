import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: телефон")
struct PhoneTests {
    @Test("Поиск находит номер и без пробелов: в тексте поиска — цифры подряд")
    func searchDigits() {
        let columns = PropertyTypes.type(for: .phone).comparables(.string("+7 900 123-45-67"), in: TypeFixture.context(.phone))
        #expect(columns.searchText?.contains("79001234567") == true)
    }
}
