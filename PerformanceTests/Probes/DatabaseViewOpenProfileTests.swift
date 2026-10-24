import AppKit
import DatabaseGrid
import DatabaseViewBar
import Databases
import NotesCore
import XCTest

/// Диагностика открытия «Задачи — работа» по частям (T085): запрос, группы, строки сетки, вид, раскладка, рисование.
/// Не приёмочный замер: бюджет — `DatabaseViewPerformanceTests`. Запускается только адресно
/// (`TEST_RUNNER_MYNOTION_PERF_PROFILE=1`); с `MYNOTION_PERF_PROFILE_READY` пишет свой PID и повторяет открытие 12 с
/// для `sample`.
@MainActor
final class DatabaseViewOpenProfileTests: XCTestCase {
    func testWorkViewOpenParts() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MYNOTION_PERF_PROFILE"] == "1", "Запускается адресным profile-скриптом")
        let library = try DatabaseProbeLibrary.copy()
        defer { library.store.database.close(); try? FileManager.default.removeItem(at: library.folder) }
        let store = library.store, sample = library.sample
        store.addWriteHook(CellIndexer())
        let operations = DatabaseOperations(store: store)
        let window = DatabaseProbeWindow()
        defer { window.close() }
        // Те же условия, что у бюджета: перед открытием в окне — «Таблица».
        let table = try XCTUnwrap(DatabaseTableController(store: store, operations: operations, databaseId: sample.tasksId,
                                                          viewId: sample.tableViewId))
        window.show(DatabaseTableView(controller: table, mode: .page))
        window.render()
        window.pump(200)

        var parts: [String: [Double]] = [:]
        func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        func lap(_ name: String, _ start: inout UInt64) {
            let end = now()
            parts[name, default: []].append(Double(end - start) / 1_000_000)
            start = end
        }
        let presented = try XCTUnwrap(try ViewQuery.present(sample.workViewId, in: store))
        var spec = ViewQuerySpec(view: presented.view)
        spec.groupPropertyId = nil
        for round in 0..<40 {
            window.pump(20)
            var start = now()
            _ = try ViewQuery.present(sample.workViewId, in: store)
            lap("1 present целиком", &start)
            _ = try ViewQuery.rows(spec, catalog: presented.catalog, in: store)
            lap("2 из него SQL", &start)
            _ = try store.write { try $0.database(sample.tasksId)?.isInline }
            lap("3 isInline (запись)", &start)
            window.pump(5)
            start = now()
            let first = start
            let work = try XCTUnwrap(DatabaseTableController(store: store, operations: operations, databaseId: sample.tasksId,
                                                             viewId: sample.workViewId))
            lap("4 контроллер", &start)
            let view = DatabaseTableView(controller: work, mode: .page)
            lap("5 DatabaseTableView.init", &start)
            window.show(view)
            lap("6 show (вставка и раскладка)", &start)
            window.window.contentView?.layoutSubtreeIfNeeded()
            lap("7 раскладка", &start)
            window.window.displayIfNeeded()
            lap("8 рисование", &start)
            CATransaction.flush()
            lap("9 передача", &start)
            parts["0 открытие целиком", default: []].append(Double(start - first) / 1_000_000)
            if round < 4 { parts.keys.forEach { parts[$0]?.removeAll() } }
        }
        let pragmas = try store.write { tx in
            try ["cache_size", "mmap_size", "page_size", "journal_mode"].map { "\($0)=\(try tx.fetchTexts(sql: "PRAGMA \($0)").first ?? "-")" }
        }
        let plan = try ViewQuery.plan(spec, catalog: presented.catalog, in: store)
        let summary = parts.sorted { $0.key < $1.key }.map {
            "\($0.key): медиана \(ProbeEditor.format(ProbeEditor.median($0.value))), p95 \(ProbeEditor.format(ProbeEditor.p95($0.value)))"
        }.joined(separator: "\n")
        print("US3 OPEN PARTS (\(parts["0 открытие целиком"]?.count ?? 0) кругов, мс)\n\(summary)\nPRAGMA: \(pragmas.joined(separator: ", "))\nPLAN: \(plan.joined(separator: " | "))")
        fflush(nil)

        guard let path = environment["MYNOTION_PERF_PROFILE_READY"] else { return }
        let ready: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "bundle": Bundle(for: Self.self).bundleURL.path]
        try JSONSerialization.data(withJSONObject: ready).write(to: URL(fileURLWithPath: path), options: .atomic)
        let until = Date().addingTimeInterval(12)
        var rounds = 0
        repeat {
            try autoreleasepool {
                let work = try XCTUnwrap(DatabaseTableController(store: store, operations: operations, databaseId: sample.tasksId,
                                                                 viewId: sample.workViewId))
                window.show(DatabaseTableView(controller: work, mode: .page))
                window.render()
                window.pump(5)
            }
            rounds += 1
        } while Date() < until
        print("US3 OPEN PROFILE DONE: \(rounds) открытий; времена не приёмочные")
    }
}
