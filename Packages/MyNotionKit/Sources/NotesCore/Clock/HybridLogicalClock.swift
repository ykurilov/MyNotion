import Foundation
import Synchronization

/// Метка гибридных часов: время Mac в миллисекундах, счётчик и id устройства (research R8).
/// Порядок меток одинаков на всех Mac: время, затем счётчик, затем id устройства.
public struct HybridTimestamp: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let wallMillis: Int64
    public let counter: UInt32
    public let deviceId: UUID

    public init(wallMillis: Int64, counter: UInt32, deviceId: UUID) {
        self.wallMillis = wallMillis
        self.counter = counter
        self.deviceId = deviceId
    }

    /// `<время, 16 hex>-<счётчик, 8 hex>-<id устройства>`: строки сортируются так же, как метки.
    public var description: String {
        String(format: "%016llx-%08x-", UInt64(wallMillis), counter) + deviceKey
    }

    public init?(_ description: String) {
        var text = description
        guard let stamp = text.withUTF8({ Self.parse($0[...]) }) else { return nil }
        self = stamp
    }

    /// Длина записи метки: 16 + 1 + 8 + 1 + 36.
    static let textLength = 62

    /// Разбор записи метки по байтам: метки читаются на каждом блоке открываемой страницы (research R15).
    static func parse(_ bytes: Slice<UnsafeBufferPointer<UInt8>>) -> HybridTimestamp? {
        guard bytes.count == textLength else { return nil }
        let start = bytes.startIndex
        guard let wall = hex(bytes, start, 16), wall <= UInt64(Int64.max), bytes[start + 16] == UInt8(ascii: "-"),
              let counter = hex(bytes, start + 17, 8), bytes[start + 25] == UInt8(ascii: "-") else { return nil }
        // UUID: 8-4-4-4-12 шестнадцатеричных цифр.
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let isValid = withUnsafeMutableBytes(of: &uuid) { raw -> Bool in
            var position = start + 26, byte = 0
            for group in [8, 4, 4, 4, 12] {
                for _ in 0..<group / 2 {
                    guard let value = hex(bytes, position, 2) else { return false }
                    raw[byte] = UInt8(value)
                    byte += 1
                    position += 2
                }
                if group != 12 {
                    guard bytes[position] == UInt8(ascii: "-") else { return false }
                    position += 1
                }
            }
            return true
        }
        guard isValid else { return nil }
        let deviceId = UUID(uuid: uuid)
        return HybridTimestamp(wallMillis: Int64(wall), counter: UInt32(counter), deviceId: deviceId)
    }

    private static func hex(_ bytes: Slice<UnsafeBufferPointer<UInt8>>, _ start: Int, _ count: Int) -> UInt64? {
        var value: UInt64 = 0
        for index in start..<start + count {
            let digit: UInt8
            switch bytes[index] {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = bytes[index] - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = bytes[index] - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = bytes[index] - UInt8(ascii: "A") + 10
            default: return nil
            }
            value = value << 4 | UInt64(digit)
        }
        return value
    }

    public static func < (lhs: HybridTimestamp, rhs: HybridTimestamp) -> Bool {
        (lhs.wallMillis, lhs.counter, lhs.deviceKey) < (rhs.wallMillis, rhs.counter, rhs.deviceKey)
    }

    private var deviceKey: String { deviceId.uuidString.lowercased() }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let stamp = HybridTimestamp(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Не метка гибридных часов: \(text)")
        }
        self = stamp
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Гибридные часы устройства: метки растут всегда, даже если время Mac отстало,
/// и после приёма чужой метки свои идут позже неё.
public final class HybridLogicalClock: Sendable {
    public let deviceId: UUID
    private let wallClock: @Sendable () -> Int64
    private let latest: Mutex<(wallMillis: Int64, counter: UInt32)>

    public init(deviceId: UUID, wallClock: @escaping @Sendable () -> Int64 = HybridLogicalClock.systemMillis) {
        self.deviceId = deviceId
        self.wallClock = wallClock
        self.latest = Mutex((wallMillis: Int64.min, counter: 0))
    }

    public static let systemMillis: @Sendable () -> Int64 = {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }

    /// Метка для своего изменения.
    public func now() -> HybridTimestamp {
        let wall = wallClock()
        return latest.withLock { state in
            if wall > state.wallMillis {
                state = (wall, 0)
            } else {
                state.counter += 1
            }
            return HybridTimestamp(wallMillis: state.wallMillis, counter: state.counter, deviceId: deviceId)
        }
    }

    /// Учесть метку, пришедшую с другого Mac; возвращает метку момента приёма.
    @discardableResult
    public func receive(_ remote: HybridTimestamp) -> HybridTimestamp {
        let wall = wallClock()
        return latest.withLock { state in
            let maxWall = max(wall, state.wallMillis, remote.wallMillis)
            let counter: UInt32
            switch (maxWall == state.wallMillis, maxWall == remote.wallMillis) {
            case (true, true): counter = max(state.counter, remote.counter) + 1
            case (true, false): counter = state.counter + 1
            case (false, true): counter = remote.counter + 1
            case (false, false): counter = 0
            }
            state = (maxWall, counter)
            return HybridTimestamp(wallMillis: maxWall, counter: counter, deviceId: deviceId)
        }
    }
}

/// Постоянный id этого Mac: создаётся при первом обращении и хранится в настройках.
public enum DeviceIdentity {
    static let defaultsKey = "MyNotion.deviceId"

    public static func deviceId(in defaults: UserDefaults = .standard) -> UUID {
        deviceId(key: defaultsKey, in: defaults)
    }

    /// Свой id для базы не на обычном месте (`--database`): два экземпляра с разными базами — как два Mac.
    public static func deviceId(forDatabaseAt url: URL, in defaults: UserDefaults = .standard) -> UUID {
        deviceId(key: defaultsKey + "." + url.standardizedFileURL.path, in: defaults)
    }

    private static func deviceId(key: String, in defaults: UserDefaults) -> UUID {
        if let stored = defaults.string(forKey: key), let id = UUID(uuidString: stored) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }
}
