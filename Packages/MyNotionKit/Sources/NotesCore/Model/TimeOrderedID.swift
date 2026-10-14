import Foundation
import Synchronization

extension UUID {
    /// UUID версии 7 (RFC 9562): первые 48 бит — время в миллисекундах, затем счётчик,
    /// поэтому id, созданные на одном Mac, упорядочены по времени даже в пределах миллисекунды.
    public static func timeOrdered() -> UUID {
        TimeOrderedIDGenerator.shared.next()
    }
}

final class TimeOrderedIDGenerator: Sendable {
    static let shared = TimeOrderedIDGenerator()

    /// Последняя выданная миллисекунда и 12-битный счётчик внутри неё.
    private let state = Mutex<(millis: UInt64, counter: UInt16)>((0, 0))

    func next() -> UUID {
        let now = UInt64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        let (millis, counter) = state.withLock { state -> (UInt64, UInt16) in
            if now > state.millis {
                state = (now, UInt16.random(in: 0..<0x800))
            } else if state.counter < 0xFFF {
                state.counter += 1
            } else {
                state = (state.millis + 1, 0)
            }
            return (state.millis, state.counter)
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8(truncatingIfNeeded: millis >> (8 * (5 - i))) }
        bytes[6] = 0x70 | UInt8(counter >> 8)
        bytes[7] = UInt8(truncatingIfNeeded: counter)
        var random = SystemRandomNumberGenerator()
        for i in 8..<16 { bytes[i] = random.next() }
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
