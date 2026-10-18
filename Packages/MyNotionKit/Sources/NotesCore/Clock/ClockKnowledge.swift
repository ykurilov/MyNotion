import Foundation

/// Какие правки видел Mac: по каждому устройству — самая поздняя его метка (research R8).
/// Правки одного устройства доходят по порядку, поэтому метка не позже известной — тоже известна.
/// По этому решается, стирали ли страницу «не видя правки» на другом Mac.
public struct ClockKnowledge: Sendable, Hashable, Codable {
    public private(set) var latestByDevice: [UUID: HybridTimestamp]

    public init(latestByDevice: [UUID: HybridTimestamp] = [:]) {
        self.latestByDevice = latestByDevice
    }

    public init(_ stamps: some Sequence<HybridTimestamp>) {
        self.init()
        for stamp in stamps { record(stamp) }
    }

    public mutating func record(_ stamp: HybridTimestamp) {
        if let known = latestByDevice[stamp.deviceId], known >= stamp { return }
        latestByDevice[stamp.deviceId] = stamp
    }

    public mutating func merge(_ other: ClockKnowledge) {
        for stamp in other.latestByDevice.values { record(stamp) }
    }

    /// Правка с этой меткой была известна.
    public func covers(_ stamp: HybridTimestamp) -> Bool {
        guard let known = latestByDevice[stamp.deviceId] else { return false }
        return stamp <= known
    }

    public var isEmpty: Bool { latestByDevice.isEmpty }

    /// `{"<id устройства>":"<метка>"}`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stamps = try container.decode([String: HybridTimestamp].self)
        self.init(stamps.values)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: latestByDevice.map { ($0.key.uuidString.lowercased(), $0.value) }))
    }
}

extension HybridTimestamp {
    /// Метка раньше любой настоящей: у поля ещё не было правок.
    public static let distantPast = HybridTimestamp(wallMillis: 0, counter: 0,
                                                    deviceId: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)
}
