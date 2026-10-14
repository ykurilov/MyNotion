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
        let parts = description.split(separator: "-", maxSplits: 2)
        guard parts.count == 3, parts[0].count == 16, parts[1].count == 8,
              let wall = UInt64(parts[0], radix: 16), wall <= UInt64(Int64.max),
              let counter = UInt32(parts[1], radix: 16),
              let deviceId = UUID(uuidString: String(parts[2]))
        else { return nil }
        self.init(wallMillis: Int64(wall), counter: counter, deviceId: deviceId)
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
        if let stored = defaults.string(forKey: defaultsKey), let id = UUID(uuidString: stored) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: defaultsKey)
        return id
    }
}
