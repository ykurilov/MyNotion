import AppKit
import XCTest

/// Первое заполнение индекса обратных ссылок на эталонной базе (1 000 страниц, 100 000 блоков) не мешает работе (T074, SC-206):
/// целиком — до 5 с, окно не стоит дольше 100 мс, запись при наборе ждёт не больше 50 мс.
/// Сборка Release. Приложение запускается с флагом `--backlink-benchmark`: само стирает индекс, строит его заново,
/// меряет остановки главного потока и задержки записи, пишет отчёт и выходит.
final class BacklinkIndexTests: XCTestCase {
    static let buildBudgetSeconds = 5.0
    static let stallBudgetMilliseconds = 100.0
    static let writeBudgetMilliseconds = 50.0

    func testFirstBuildDoesNotDisturbTyping() throws {
        let library = try Self.libraryCopy()
        defer { try? FileManager.default.removeItem(at: library.deletingLastPathComponent()) }
        let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("backlink-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: reportURL) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = ["--database", library.path, "--backlink-benchmark", reportURL.path]
        let app = try launch(LaunchAndMemoryTests.builtAppURL(), configuration: configuration)
        defer { if !app.isTerminated { app.forceTerminate() } }

        let report = try Self.waitForReport(at: reportURL, timeout: 120)
        if let error = report.error { XCTFail("Замер прерван: \(error)") }

        let summary = """
            Индекс обратных ссылок: \(report.pageCount) страниц, \(report.blockCount) блоков, ссылок в индексе \(report.linkCount) (блоков со ссылкой \(report.seededBlockCount)); \
            заполнение \(Self.format(report.buildSeconds)) с; остановка окна p95 \(Self.format(report.mainThreadStallMsP95)) мс, \
            худшая \(Self.format(report.mainThreadStallMsMax)) мс; запись при наборе p95 \(Self.format(report.writeLatencyMsP95)) мс, \
            худшая \(Self.format(report.writeLatencyMsMax)) мс (\(report.writeLatencyMs.count) записей)
            """
        print(summary)
        add(XCTAttachment(string: summary))

        XCTAssertGreaterThan(report.linkCount, 0, "Индекс остался пустым: замер ничего не заполнял")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.buildSeconds), Self.buildBudgetSeconds, "Заполнение индекса дольше 5 с")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.mainThreadStallMsMax), Self.stallBudgetMilliseconds, "Окно стояло дольше 100 мс")
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.writeLatencyMsP95), Self.writeBudgetMilliseconds, "Запись при наборе ждёт дольше 50 мс (p95)")
    }

    // MARK: Вспомогательное

    /// Замер размечает блоки ссылками, поэтому работает на копии эталона.
    private static func libraryCopy() throws -> URL {
        let source = try ReferenceLibrary.url()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyNotion-backlinks-\(UUID().uuidString)", isDirectory: true)
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

    private struct BacklinkReport: Decodable {
        let pageCount: Int
        let blockCount: Int
        let linkCount: Int
        let seededBlockCount: Int
        let buildSeconds: Double?
        let mainThreadStallMsP95: Double?
        let mainThreadStallMsMax: Double?
        let writeLatencyMs: [Double]
        let writeLatencyMsP95: Double?
        let writeLatencyMsMax: Double?
        let error: String?
    }

    private static func waitForReport(at url: URL, timeout: TimeInterval) throws -> BacklinkReport {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), let report = try? JSONDecoder().decode(BacklinkReport.self, from: data) {
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
