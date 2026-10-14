import Foundation
import Testing
@testable import NotesCore

@Suite("Гибридные часы")
struct HybridLogicalClockTests {
    let deviceA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let deviceB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    @Test("Метки растут, даже когда системные часы Mac отстали")
    func monotonicWhenWallClockGoesBack() {
        let wall = AdjustableWallClock(millis: 10_000)
        let clock = HybridLogicalClock(deviceId: deviceA, wallClock: wall.reading)

        let first = clock.now()
        wall.set(4_000)
        let second = clock.now()
        let third = clock.now()

        #expect(first < second)
        #expect(second < third)
        #expect(second.wallMillis == 10_000)
    }

    @Test("Время Mac идёт вперёд — метка берёт его, счётчик сбрасывается")
    func followsWallClockForward() {
        let wall = AdjustableWallClock(millis: 1_000)
        let clock = HybridLogicalClock(deviceId: deviceA, wallClock: wall.reading)

        _ = clock.now()
        _ = clock.now()
        wall.set(2_000)
        let later = clock.now()

        #expect(later.wallMillis == 2_000)
        #expect(later.counter == 0)
    }

    @Test("Чужая метка из будущего сдвигает часы: следующая своя метка позже чужой")
    func receivesRemoteTimestamp() {
        let wall = AdjustableWallClock(millis: 1_000)
        let clock = HybridLogicalClock(deviceId: deviceA, wallClock: wall.reading)
        let remote = HybridTimestamp(wallMillis: 50_000, counter: 7, deviceId: deviceB)

        let afterReceive = clock.receive(remote)
        let next = clock.now()

        #expect(afterReceive > remote)
        #expect(afterReceive.deviceId == deviceA)
        #expect(next > afterReceive)
        #expect(next.wallMillis == 50_000)
    }

    @Test("Одинаковые время и счётчик — порядок решает id устройства")
    func tieBreaksByDeviceId() {
        let fromA = HybridTimestamp(wallMillis: 5_000, counter: 2, deviceId: deviceA)
        let fromB = HybridTimestamp(wallMillis: 5_000, counter: 2, deviceId: deviceB)

        #expect(fromA < fromB)
        #expect(!(fromB < fromA))
        #expect(fromA != fromB)
    }

    @Test("Строковое представление сортируется так же, как сравнение меток")
    func stringFormSortsLikeComparison() throws {
        var generator = SystemRandomNumberGenerator()
        let devices = (0..<5).map { _ in UUID() }
        let stamps = (0..<2_000).map { _ in
            HybridTimestamp(
                wallMillis: Int64.random(in: 0...4_102_444_800_000, using: &generator),
                counter: UInt32.random(in: 0...3, using: &generator),
                deviceId: devices.randomElement(using: &generator)!
            )
        }
        // Повторы времени и счётчика, чтобы сработал разрыв ничьей.
        let withTies = stamps + stamps.prefix(200).map {
            HybridTimestamp(wallMillis: $0.wallMillis, counter: $0.counter, deviceId: devices.randomElement()!)
        }

        let byComparison = withTies.sorted()
        let byString = withTies.sorted { $0.description.utf8.lexicographicallyPrecedes($1.description.utf8) }
        #expect(byComparison.map(\.description) == byString.map(\.description))

        for stamp in withTies.prefix(50) {
            #expect(HybridTimestamp(stamp.description) == stamp)
        }
    }

    @Test("Id устройства создаётся один раз и потом не меняется")
    func deviceIdIsCreatedOnce() throws {
        let suite = "MyNotionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = DeviceIdentity.deviceId(in: defaults)
        let second = DeviceIdentity.deviceId(in: defaults)

        #expect(first == second)
    }
}
