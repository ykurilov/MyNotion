import AppKit
import XCTest

/// Отклик набора и переходов (T048, конституция, принцип II; условия — research R13):
/// сборка Release, эталонная база, страница на 1 000 блоков открыта при запуске.
/// Приложение запускается через систему с флагом `--typing-benchmark`: оно само печатает 200 нажатий,
/// переходит между страницами, затем печатает и листает страницу на 10 000 блоков, пишет время
/// каждого действия (signpost-интервалы `Keystroke`, `PageSwitch`, `Scroll`) в отчёт и выходит.
final class TypingAndNavigationTests: XCTestCase {
    static let budgetMilliseconds = 50.0

    func testTypingAndPageSwitchingWithinBudget() throws {
        // Своя копия эталона: замер добавляет страницу на 10 000 блоков и печатает в страницах.
        let library = try Self.libraryCopy()
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("typing-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: reportURL) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = ["--database", library.path, "--typing-benchmark", reportURL.path]
        let app = try launch(LaunchAndMemoryTests.builtAppURL(), configuration: configuration)
        defer { if !app.isTerminated { app.forceTerminate() } }

        let report = try Self.waitForReport(at: reportURL, timeout: 180)
        if let error = report.error { XCTFail("Замер прерван: \(error)") }

        let summary = """
            Набор в странице на 1 000 блоков: p95 \(Self.format(report.typingP95Ms)) мс, \(report.typingMs.count) нажатий
            Переход между страницами: p95 \(Self.format(report.pageSwitchP95Ms)) мс, медиана \(Self.format(Self.median(report.pageSwitchMs))) мс, \
            худший \(Self.format(report.pageSwitchMs.max())) мс, \(report.pageSwitchMs.count) переходов
            Открытие страницы на 10 000 блоков: \(Self.format(report.hugePageOpenMs)) мс
            Набор в странице на 10 000 блоков: p95 \(Self.format(report.hugePageTypingP95Ms)) мс
            Прокрутка страницы на 10 000 блоков: p95 \(Self.format(report.hugePageScrollP95Ms)) мс
            """
        print(summary)
        add(XCTAttachment(string: summary))

        XCTAssertEqual(report.typingMs.count, 200, "Не все нажатия дошли до страницы")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.typingP95Ms), Self.budgetMilliseconds, "Набор: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.pageSwitchP95Ms), Self.budgetMilliseconds, "Переход: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.hugePageTypingP95Ms), Self.budgetMilliseconds,
                                 "Набор на 10 000 блоках: p95 больше 50 мс")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.hugePageScrollP95Ms), Self.budgetMilliseconds,
                                 "Прокрутка 10 000 блоков: p95 больше 50 мс")
    }

    // MARK: Вспомогательное

    private static func libraryCopy() throws -> URL {
        let source = try ReferenceLibrary.url()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-typing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

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

    private struct TypingReport: Decodable {
        let typingMs: [Double]
        let pageSwitchMs: [Double]
        let hugePageOpenMs: Double?
        let typingP95Ms: Double?
        let pageSwitchP95Ms: Double?
        let hugePageTypingP95Ms: Double?
        let hugePageScrollP95Ms: Double?
        let error: String?
    }

    private static func waitForReport(at url: URL, timeout: TimeInterval) throws -> TypingReport {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), let report = try? JSONDecoder().decode(TypingReport.self, from: data) {
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

    private static func median(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.sorted()[values.count / 2]
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }
}
