import Foundation
import XCTest
@testable import Databases
@testable import NotesCore

/// Проба остановки главного потока при первом заполнении итогов (US5, T056): эталон «Задачи» 10 000 строк, итоги трёх формул
/// стёрты, `fillMissing` в фоне. Пульс главного потока (таймер 5 мс) и пульс фонового потока (сон 5 мс): если оба стоят
/// в одно время, — стоял весь процесс (машина), а не главный поток. Тяжёлая: только с `MYNOTION_FIRST_FILL_PROBE=1`.
@MainActor
final class FirstFillMainThreadProbe: XCTestCase {
    func testFirstFillKeepsMainThreadFree() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYNOTION_FIRST_FILL_PROBE"] == "1", "проба включается MYNOTION_FIRST_FILL_PROBE=1")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("first-fill-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("MyNotion.sqlite")
        // Генерация эталона копит в пуле автоосвобождения мусор (снимки стека `_NSCallStackArray`); без своего пула его
        // освобождает главный поток уже во время замера — остановка подготовки теста, а не заполнения.
        try autoreleasepool { try DatabaseSampleGenerator().generate(at: url) }
        let store = NotesStore(database: try AppDatabase.open(at: url), clock: HybridLogicalClock(deviceId: UUID()))
        defer { store.database.close() }
        let sample = try XCTUnwrap(try DatabaseSampleGenerator.existing(in: store))
        let queue = FormulaRecomputeQueue(store: store)
        store.addWriteHook(CellIndexer())
        store.addWriteHook(ComputationHook(store: store, queue: queue))
        let formulas = ["Дней до срока", "Итог", "Проект (имя)"].map { sample.taskProperties[$0]! }
        try store.write { tx in
            for id in formulas { try tx.execute(sql: "DELETE FROM db_computed WHERE propertyId = ?", arguments: [.text(id.uuidString.lowercased())]) }
        }

        let main = Pulse(), background = Pulse()
        let watchdog = ProbeMainThreadWatchdog(thresholdMs: 100)
        defer { watchdog.stop() }
        let ticker = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in main.beat(); watchdog.tick() }
        let beating = Beating()
        Thread.detachNewThread { while beating.isOn { background.beat(); usleep(5_000) } }
        let started = Date()
        queue.fillMissing()
        await Task.detached { queue.waitUntilIdle() }.value
        let seconds = Date().timeIntervalSince(started)
        ticker.invalidate()
        beating.isOn = false
        print("Проба первого заполнения: \(String(format: "%.2f", seconds)) с; главный поток: \(main.report); фоновый пульс: \(background.report)")
        print("Проба первого заполнения, стек главного потока при остановке: \(watchdog.report)")
        XCTAssertLessThanOrEqual(main.longest, 100, "Главный поток стоял дольше 100 мс: \(main.report); фоновый пульс: \(background.report)")
    }
}

/// Пульс потока: самый долгий промежуток между ударами и остановки дольше 100 мс (когда от начала, сколько).
final class Pulse: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private var last = Date()
    private(set) var longest = 0.0
    private var stalls: [(Double, Double)] = []

    func beat() {
        lock.withLock {
            let now = Date(), gap = now.timeIntervalSince(last) * 1_000
            if gap > 100 { stalls.append((last.timeIntervalSince(start) * 1_000, gap)) }
            longest = max(longest, gap)
            last = now
        }
    }

    var report: String {
        lock.withLock {
            "до \(Int(longest)) мс" + (stalls.isEmpty ? "" : ", остановки: " + stalls.map { "с \(Int($0.0)) мс на \(Int($0.1))" }.joined(separator: ", "))
        }
    }
}

final class Beating: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}
