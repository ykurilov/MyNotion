import Foundation

/// Кадр протокола — одна строка UTF-8 JSON с `\n` в конце. Переводы строк внутри текста JSON экранирует сам.
public enum LineFraming {
    public static let newline = UInt8(ascii: "\n")

    public static func frame<Value: Encodable>(_ value: Value) throws -> Data {
        var data = try ControlCoding.encoder.encode(value)
        data.append(newline)
        return data
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from line: Data) throws -> Value {
        try ControlCoding.decoder.decode(type, from: line)
    }
}

/// Накопитель кадров из потока байт: отдаёт целые строки, следит за пределом размера.
public struct LineBuffer: Sendable {
    public let limit: Int
    private var pending = Data()
    /// Сколько байт `pending` уже проверено на `\n`: медленный клиент не заставляет перебирать накопленное заново.
    private var scanned = 0

    public init(limit: Int = ControlProtocolVersion.maxFrameBytes) {
        self.limit = limit
    }

    public enum Failure: Error, Equatable {
        /// Строка длиннее предела — запрос отклоняется целиком.
        case frameTooLarge
    }

    /// Дописать байты и забрать готовые строки (без `\n`).
    public mutating func append(_ data: Data) throws(Failure) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        var lineStart = pending.startIndex
        var searchFrom = pending.startIndex + scanned
        while let end = pending[searchFrom...].firstIndex(of: LineFraming.newline) {
            guard end - lineStart <= limit else { throw .frameTooLarge }
            lines.append(Data(pending[lineStart..<end]))
            lineStart = pending.index(after: end)
            searchFrom = lineStart
        }
        if lineStart > pending.startIndex { pending = Data(pending[lineStart...]) }
        scanned = pending.count
        guard pending.count <= limit else { throw .frameTooLarge }
        return lines
    }

    /// Хвост без `\n` — при закрытии связи.
    public var remainder: Data { pending }
}
