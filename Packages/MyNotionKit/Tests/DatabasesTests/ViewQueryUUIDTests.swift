import Foundation
import Testing
@testable import Databases

@Suite("UUID запроса: эквивалентность Foundation")
struct ViewQueryUUIDTests {
    @Test("Корректные UUID: нижний, верхний и смешанный регистр")
    func canonicalAndMixedCase() {
        let forms = ["abcdef01-2345-6789-abcd-ef0123456789", "ABCDEF01-2345-6789-ABCD-EF0123456789",
                     "aBcDeF01-2345-6789-aBcD-eF0123456789", "00000000-0000-0000-0000-000000000000",
                     "ffffffff-ffff-ffff-ffff-ffffffffffff"]
        for text in forms {
            #expect(UUID(uuidString: text) != nil)
            #expect(ViewQuerySQL.uuid(text) == UUID(uuidString: text))
        }
    }

    @Test("Повреждённые и неканонические строки следуют прежнему Foundation parser")
    func malformedAndFallback() {
        let canonical = "abcdef01-2345-6789-abcd-ef0123456789"
        var forms = ["", "not-a-uuid", " " + canonical, canonical + " ", "{" + canonical + "}",
                     canonical.replacingOccurrences(of: "-", with: ""), canonical + "x", "😀" + canonical,
                     canonical.replacingOccurrences(of: "a", with: "а"), canonical + "\0"]
        let bytes = Array(canonical.utf8)
        for index in bytes.indices {
            var invalid = bytes
            invalid[index] = 103 // g не является hex-цифрой; проверяются и места дефисов.
            forms.append(String(decoding: invalid, as: UTF8.self))
            forms.append(String(canonical.prefix(index)))
        }
        for text in forms {
            #expect(ViewQuerySQL.uuid(text) == UUID(uuidString: text), "Строка: \(String(reflecting: text))")
        }
    }
}
