import Foundation
import Testing
@testable import Databases
@testable import NotesCore

@Suite("Тип: файлы и медиа")
struct FilesTests {
    let type = PropertyTypes.type(for: .files)
    let context = TypeFixture.context(.files)
    let value: JSONValue = [["url": "https://example.com/a.pdf", "name": "a.pdf"],
                            ["attachment": ["id": "0193A1B2-0000-7000-8000-0000000000F9", "name": "Фото.png", "byteCount": 10,
                                            "contentType": "public.png", "sha256": "x", "partCount": 1]]]

    @Test("sortNumber — число файлов; поиск — имена; CSV — имена через «, »")
    func values() {
        #expect(type.comparables(value, in: context) == CellComparables(sortText: "a.pdf", sortNumber: 2, searchText: "a.pdf фото.png"))
        #expect(type.csvText(value, in: context) == "a.pdf, Фото.png")
        #expect(type.parseCSV("https://example.com/b.pdf", in: context) == .value([["url": "https://example.com/b.pdf", "name": "b.pdf"]]))
    }

    @Test("Условия — пусто / не пусто; не группируется")
    func operators() {
        #expect(type.filterOperators == [.isEmpty, .isNotEmpty])
        #expect(!type.isGroupable)
    }
}
