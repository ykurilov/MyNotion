import AppKit
import XCTest

/// Вкладки (US3, T056; SC-201, SC-202): сборка Release, копия эталонной базы. Приложение с флагом `--tabs-benchmark`
/// само открывает 20 вкладок с «богатыми» страницами 002, переключает их 100 раз, ходит «назад» и «вперёд» и пишет
/// отчёт; в конце оставляет в базе 10 вкладок. Затем запуск с этими 10 вкладками — до готовности к вводу.
final class TabsPerformanceTests: XCTestCase {
    static let budgetMilliseconds = 50.0
    static let memoryBudgetMB = 5.0
    static let launchBudgetSeconds = 1.0
    static let launches = 3

    func testTabSwitchingHistoryMemoryAndLaunchWithinBudget() throws {
        let library = try Self.libraryCopy()
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        let appURL = try LaunchAndMemoryTests.builtAppURL()

        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: reportURL) }
        let app = try launch(appURL, arguments: ["--database", library.path, "--tabs-benchmark", reportURL.path])
        let report: TabsReport = try Self.waitForReport(at: reportURL, timeout: 300) { _ in true }
        try terminate(app)
        if let error = report.error { XCTFail("Замер прерван: \(error)") }

        var launchSeconds: [Double] = []
        for _ in 1...Self.launches {
            let launchURL = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-launch-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: launchURL) }
            let requestedAt = Date().timeIntervalSince1970
            let launched = try launch(appURL, arguments: ["--database", library.path, "--launch-report", launchURL.path])
            let launchReport: LaunchReport = try Self.waitForReport(at: launchURL, timeout: 40) { $0.idleMemoryBytes != nil }
            try terminate(launched)
            launchSeconds.append(launchReport.editorReadyAt - requestedAt)
        }

        let memoryGrowth = (report.memoryTwentyTabsMB ?? .infinity) - (report.memoryOneTabMB ?? 0)
        let summary = """
            Переключение вкладки (20 «богатых»): p95 \(Self.format(report.switchP95Ms)) мс, медиана \(Self.format(Self.median(report.switchMs))) мс, \
            \(report.switchMs.count) переключений
            Назад: p95 \(Self.format(report.backP95Ms)) мс; вперёд: p95 \(Self.format(report.forwardP95Ms)) мс
            Место прокрутки после возврата: \(report.scrollRestored) из \(report.scrollChecked)
            Память: 1 вкладка \(Self.format(report.memoryOneTabMB)) МБ, 20 вкладок \(Self.format(report.memoryTwentyTabsMB)) МБ, \
            прирост \(Self.format(memoryGrowth)) МБ
            Запуск с 10 вкладками до EditorReady, с: \(launchSeconds.map { String(format: "%.3f", $0) }.joined(separator: ", "))
            """
        print(summary)
        add(XCTAttachment(string: summary))

        XCTAssertLessThanOrEqual(try XCTUnwrap(report.switchP95Ms), Self.budgetMilliseconds, "Переключение вкладки: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.backP95Ms), Self.budgetMilliseconds, "«Назад»: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.forwardP95Ms), Self.budgetMilliseconds, "«Вперёд»: p95 больше 50 мс")
        XCTAssertEqual(report.scrollRestored, report.scrollChecked, "Место прокрутки вернулось не на всех вкладках")
        XCTAssertLessThanOrEqual(memoryGrowth, Self.memoryBudgetMB, "20 вкладок добавили больше 5 МБ")
        XCTAssertLessThanOrEqual(try XCTUnwrap(launchSeconds.max()), Self.launchBudgetSeconds, "Запуск с 10 вкладками дольше 1 с")
    }

    // MARK: Вспомогательное

    private static func libraryCopy() throws -> URL {
        let source = try ReferenceLibrary.url()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func launch(_ appURL: URL, arguments: [String]) throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        let opened = expectation(description: "Система запустила приложение")
        nonisolated(unsafe) var result: Result<NSRunningApplication, Error>?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            result = app.map { .success($0) } ?? .failure(error ?? AppLaunchFailed())
            opened.fulfill()
        }
        wait(for: [opened], timeout: 30)
        return try XCTUnwrap(result).get()
    }

    private func terminate(_ app: NSRunningApplication) throws {
        let deadline = Date().addingTimeInterval(10)
        if !app.isTerminated { app.terminate() }
        while !app.isTerminated && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if !app.isTerminated { app.forceTerminate() }
    }

    private struct AppLaunchFailed: Error {}

    private struct TabsReport: Decodable {
        let switchMs: [Double]
        let switchP95Ms: Double?
        let backP95Ms: Double?
        let forwardP95Ms: Double?
        let memoryOneTabMB: Double?
        let memoryTwentyTabsMB: Double?
        let scrollRestored: Int
        let scrollChecked: Int
        let error: String?
    }

    private struct LaunchReport: Decodable {
        let editorReadyAt: Double
        let idleMemoryBytes: UInt64?
    }

    private static func waitForReport<Report: Decodable>(at url: URL, timeout: TimeInterval, until isComplete: (Report) -> Bool) throws -> Report {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), let report = try? JSONDecoder().decode(Report.self, from: data), isComplete(report) {
                return report
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        throw ReportMissing(path: url.path, timeout: timeout)
    }

    private struct ReportMissing: Error, CustomStringConvertible {
        let path: String
        let timeout: TimeInterval
        var description: String { "Приложение не записало отчёт за \(Int(timeout)) с: \(path)" }
    }

    private static func median(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }
}
