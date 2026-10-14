import Foundation
import Synchronization
@testable import NotesCore

/// Системные часы Mac под управлением теста.
final class AdjustableWallClock: Sendable {
    private let currentMillis: Mutex<Int64>

    init(millis: Int64 = 1_000) {
        currentMillis = Mutex(millis)
    }

    func set(_ millis: Int64) {
        currentMillis.withLock { $0 = millis }
    }

    var reading: @Sendable () -> Int64 {
        { [self] in currentMillis.withLock { $0 } }
    }
}

/// Пустая папка на время теста; стирается вместе с объектом.
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyNotionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var databaseURL: URL { url.appendingPathComponent("MyNotion.sqlite") }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

struct DeliberateFailure: Error {}
