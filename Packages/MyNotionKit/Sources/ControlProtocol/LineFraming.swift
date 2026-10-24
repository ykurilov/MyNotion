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
        while let end = pending.firstIndex(of: LineFraming.newline) {
            let line = pending[pending.startIndex..<end]
            guard line.count <= limit else { throw .frameTooLarge }
            lines.append(Data(line))
            pending = Data(pending[pending.index(after: end)...])
        }
        guard pending.count <= limit else { throw .frameTooLarge }
        return lines
    }

    /// Хвост без `\n` — при закрытии связи.
    public var remainder: Data { pending }
}
