import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: email")
struct EmailTests {
    @Test("Пустая строка — пусто")
    func empty() {
        #expect(PropertyTypes.type(for: .email).parseCSV("  ", in: TypeFixture.context(.email)) == .value(nil))
    }
}
