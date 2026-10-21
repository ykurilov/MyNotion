import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Типы: ссылка, email, телефон")
struct URLTests {
    @Test("Значение — текст как есть; сравнимое — нижний регистр; CSV и разбор — как есть; условия текста")
    func plainTextKinds() {
        for (kind, raw) in [(PropertyKind.url, "https://Example.com/A"), (.email, "Me@Example.com"), (.phone, "+7 900 123-45-67")] {
            let type = PropertyTypes.type(for: kind)
            let context = TypeFixture.context(kind)
            #expect(type.comparables(.string(raw), in: context) == CellComparables(sortText: raw.lowercased(), searchText: raw.lowercased()))
            #expect(type.displayText(.string(raw), in: context) == raw)
            #expect(type.csvText(.string(raw), in: context) == raw)
            #expect(type.parseCSV(raw, in: context) == .value(.string(raw)))
            #expect(type.filterOperators == PropertyTypes.type(for: .text).filterOperators)
        }
    }
}
