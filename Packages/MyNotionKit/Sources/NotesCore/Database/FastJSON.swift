import Foundation

/// Разбор JSON значений ячеек проходом по байтам: окно видимых строк читает тысячи маленьких значений при прокрутке,
/// `JSONDecoder` для этого в десятки раз медленнее (проба R20.1).
public enum FastJSON {
    public static func parse(_ text: String) -> JSONValue? {
        var text = text
        return text.withUTF8 { bytes in
            var parser = Parser(bytes: bytes)
            guard let value = parser.value() else { return nil }
            parser.skipSpaces()
            return parser.position == bytes.count ? value : nil
        }
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0

        mutating func skipSpaces() {
            while position < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[position]) { position += 1 }
        }

        mutating func value() -> JSONValue? {
            skipSpaces()
            guard position < bytes.count else { return nil }
            switch bytes[position] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""): return string().map(JSONValue.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: StaticString, _ value: JSONValue) -> JSONValue? {
            let count = word.utf8CodeUnitCount
            guard position + count <= bytes.count else { return nil }
            for index in 0..<count where bytes[position + index] != word.utf8Start[index] { return nil }
            position += count
            return value
        }

        mutating func number() -> JSONValue? {
            let start = position
            while position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position])
                    || [UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[position]) {
                position += 1
            }
            guard position > start else { return nil }
            let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
            return Double(text).map(JSONValue.number)
        }

        mutating func string() -> String? {
            position += 1
            let start = position
            // Быстрый путь: без экранирования — строка прямо из байтов.
            while position < bytes.count, bytes[position] != UInt8(ascii: "\""), bytes[position] != UInt8(ascii: "\\") { position += 1 }
            guard position < bytes.count else { return nil }
            if bytes[position] == UInt8(ascii: "\"") {
                defer { position += 1 }
                return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
            }
            var scalars = Array(bytes[start..<position])
            while position < bytes.count {
                let byte = bytes[position]
                if byte == UInt8(ascii: "\"") {
                    position += 1
                    return String(decoding: scalars, as: UTF8.self)
                }
                if byte != UInt8(ascii: "\\") {
                    scalars.append(byte)
                    position += 1
                    continue
                }
                position += 1
                guard position < bytes.count else { return nil }
                let escaped = bytes[position]
                position += 1
                switch escaped {
                case UInt8(ascii: "n"): scalars.append(0x0A)
                case UInt8(ascii: "t"): scalars.append(0x09)
                case UInt8(ascii: "r"): scalars.append(0x0D)
                case UInt8(ascii: "b"): scalars.append(0x08)
                case UInt8(ascii: "f"): scalars.append(0x0C)
                case UInt8(ascii: "u"):
                    guard var code = hex4() else { return nil }
                    if (0xD800...0xDBFF).contains(code), position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"),
                       bytes[position + 1] == UInt8(ascii: "u") {
                        position += 2
                        guard let low = hex4() else { return nil }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    scalars += Array(String(Character(Unicode.Scalar(code) ?? "\u{FFFD}")).utf8)
                default: scalars.append(escaped)
                }
            }
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard position + 4 <= bytes.count else { return nil }
            var code: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[position]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: return nil
                }
                code = code * 16 + digit
                position += 1
            }
            return code
        }

        mutating func array() -> JSONValue? {
            position += 1
            var items: [JSONValue] = []
            skipSpaces()
            if position < bytes.count, bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
            while true {
                guard let item = value() else { return nil }
                items.append(item)
                skipSpaces()
                guard position < bytes.count else { return nil }
                if bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
                guard bytes[position] == UInt8(ascii: ",") else { return nil }
                position += 1
            }
        }

        mutating func object() -> JSONValue? {
            position += 1
            var items: [String: JSONValue] = [:]
            skipSpaces()
            if position < bytes.count, bytes[position] == UInt8(ascii: "}") { position += 1; return .object(items) }
            while true {
                skipSpaces()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpaces()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { return nil }
                position += 1
                guard let item = value() else { return nil }
                items[key] = item
                skipSpaces()
                guard position < bytes.count else { return nil }
                if bytes[position] == UInt8(ascii: "}") { position += 1; return .object(items) }
                guard bytes[position] == UInt8(ascii: ",") else { return nil }
                position += 1
            }
        }
    }
}

extension FastJSON {
    /// Текст JSON без `JSONEncoder`: ключи по порядку строк, «/» без экранирования, целые — без «.0»
    /// (запись итогов формул и ячеек — тысячи значений на пересчёт, проба R20.3).
    public static func text(_ value: JSONValue) -> String {
        var output = ""
        write(value, to: &output)
        return output
    }

    private static func write(_ value: JSONValue, to output: inout String) {
        switch value {
        case .null: output += "null"
        case .bool(let flag): output += flag ? "true" : "false"
        case .number(let number):
            if !number.isFinite { output += "null" }
            else if number.rounded() == number, abs(number) < 1e15 { output += String(Int64(number)) }
            else { output += number.description }
        case .string(let string): writeString(string, to: &output)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                write(item, to: &output)
            }
            output += "]"
        case .object(let object):
            output += "{"
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                writeString(key, to: &output)
                output += ":"
                write(object[key]!, to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{8}": output += "\\b"
            case "\u{C}": output += "\\f"
            default:
                if scalar.value < 0x20 { output += String(format: "\\u%04x", scalar.value) } else { output.unicodeScalars.append(scalar) }
            }
        }
        output += "\""
    }
}
