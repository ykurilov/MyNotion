import AppKit
import XCTest

/// Поиск по 1 000 страниц показывает выдачу, пока человек печатает (T054, SC-009): до 100 мс на символ.
/// Сборка Release, эталонная база (research R13). Приложение запускается через систему с флагом `--search-benchmark`:
/// оно само печатает слова в поле поиска по букве, меряет каждое нажатие до выдачи на экране, пишет отчёт и выходит.
final class SearchTests: XCTestCase {
    static let budgetMilliseconds = 100.0

    func testSearchKeepsUpWithTyping() throws {
        let library = try ReferenceLibrary.url()
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("search-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: reportURL) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = ["--database", library.path, "--search-benchmark", reportURL.path]
        let app = try launch(LaunchAndMemoryTests.builtAppURL(), configuration: configuration)
        defer { if !app.isTerminated { app.forceTerminate() } }

        let report = try Self.waitForReport(at: reportURL, timeout: 120)
        if let error = report.error { XCTFail("Замер прерван: \(error)") }

        let summary = """
            Поиск по эталонной базе: p95 \(Self.format(report.keystrokeP95Ms)) мс на символ, \
            худшее \(Self.format(report.maxMs)) мс, \(report.keystrokeMs.count) нажатий; найдено по словам: \(report.resultCounts)
            """
        print(summary)
        add(XCTAttachment(string: summary))

        XCTAssertFalse(report.keystrokeMs.isEmpty, "Нажатия не дошли до поля поиска")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.keystrokeP95Ms), Self.budgetMilliseconds, "Поиск: p95 больше 100 мс на символ")
        XCTAssertTrue(report.resultCounts.dropLast().allSatisfy { $0 > 0 }, "Слова из эталона не нашлись: \(report.resultCounts)")
        XCTAssertEqual(report.resultCounts.last, 0, "Несуществующее слово нашлось")
    }

    // MARK: Вспомогательное

    private func launch(_ appURL: URL, configuration: NSWorkspace.OpenConfiguration) throws -> NSRunningApplication {
        let opened = expectation(description: "Система запустила приложение")
        nonisolated(unsafe) var result: Result<NSRunningApplication, Error>?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            result = app.map { .success($0) } ?? .failure(error ?? AppLaunchFailed())
            opened.fulfill()
        }
        wait(for: [opened], timeout: 30)
        return try XCTUnwrap(result).get()
    }

    private struct AppLaunchFailed: Error {}

    private struct SearchReport: Decodable {
        let keystrokeMs: [Double]
        let keystrokeP95Ms: Double?
        let maxMs: Double?
        let resultCounts: [Int]
        let error: String?
    }

    private static func waitForReport(at url: URL, timeout: TimeInterval) throws -> SearchReport {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), let report = try? JSONDecoder().decode(SearchReport.self, from: data) {
                return report
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        throw ReportMissing(path: url.path, timeout: timeout)
    }

    private struct ReportMissing: Error, CustomStringConvertible {
        let path: String
        let timeout: TimeInterval
        var description: String { "Приложение не записало отчёт замера за \(Int(timeout)) с: \(path)" }
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }
}
