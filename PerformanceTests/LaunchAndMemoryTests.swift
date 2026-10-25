import AppKit
import XCTest

/// Бюджет ресурсов (конституция, принцип II; условия — research R13):
/// сборка Release, эталонная база, одно окно. Порог запуска — 1 с на тёплом запуске: перед замером один прогревочный запуск.
final class LaunchAndMemoryTests: XCTestCase {
    static let launchBudgetSeconds = 1.0
    /// 200 МБ так, как их показывает «Мониторинг системы» (1 МБ = 1 048 576 байт).
    static let idleMemoryBudgetBytes: UInt64 = 200 * 1_048_576
    static let launches = 5
    /// Первый запуск после сборки холодный: системе нужно прочитать бинарник и проверить подпись. Он идёт перед замером
    /// и в зачёт не входит; пять замеренных запусков — тёплые, как повторный запуск из Dock.
    static let warmUpLaunches = 1

    /// Запуск до готовности к вводу (метка `EditorReady`) и память в покое через 10 с.
    /// Приложение запускается так же, как из Dock, — через систему (`NSWorkspace`), а не через
    /// `XCUIApplication`: обвязка UI-тестов сама добавляет к запуску 0,4–0,6 с, а её исполнитель
    /// в «песочнице» не может передать приложению флаги.
    /// Время — от просьбы теста запустить до `EditorReady` (момент пишет само приложение).
    /// Память — phys_footprint единственного процесса приложения (своих помощников у него нет).
    func testLaunchToEditorReadyAndIdleMemoryWithinBudget() throws {
        let library = try ReferenceLibrary.url()
        let appURL = try Self.builtAppURL()
        var launchSeconds: [Double] = []
        var processSeconds: [Double] = []
        var idleMemory: [UInt64] = []

        for run in (1 - Self.warmUpLaunches)...Self.launches {
            let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("launch-report-\(UUID().uuidString).json")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--database", library.path, "--launch-report", reportURL.path]

            let requestedAt = Date().timeIntervalSince1970
            let app = try launch(appURL, configuration: configuration)
            let report = try Self.waitForReport(at: reportURL, timeout: 40)
            try terminate(app)

            let seconds = report.editorReadyAt - requestedAt
            if run < 1 {
                print(String(format: "Прогрев (не в зачёте): до EditorReady %.3f с", seconds))
                continue
            }
            launchSeconds.append(seconds)
            processSeconds.append(report.launchSeconds)
            idleMemory.append(report.idleMemoryBytes ?? .max)
            print(String(format: "Запуск %d: до EditorReady %.3f с (от старта процесса %.3f с), память в покое %.1f МБ",
                         run, seconds, report.launchSeconds, Double(report.idleMemoryBytes ?? 0) / 1_048_576))
        }

        let summary = """
            Запуск до EditorReady, с: \(launchSeconds.map { String(format: "%.3f", $0) }.joined(separator: ", "))
            Из них от старта процесса, с: \(processSeconds.map { String(format: "%.3f", $0) }.joined(separator: ", "))
            Память в покое, МБ: \(idleMemory.map { String(format: "%.1f", Double($0) / 1_048_576) }.joined(separator: ", "))
            """
        print(summary)
        add(XCTAttachment(string: summary))

        XCTAssertLessThanOrEqual(launchSeconds.max()!, Self.launchBudgetSeconds, "Запуск дольше 1 с")
        XCTAssertLessThanOrEqual(idleMemory.max()!, Self.idleMemoryBudgetBytes, "Память в покое больше 200 МБ")
    }

    // MARK: Запуск через систему

    /// Сборка приложения лежит рядом с бандлом тестов: `<Products>/PerformanceTests.xctest`.
    static func builtAppURL() throws -> URL {
        let products = Bundle(for: LaunchAndMemoryTests.self).bundleURL.deletingLastPathComponent()
        let app = products.appendingPathComponent("MyNotion.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw AppBuildMissing(path: app.path) }
        return app
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

    private func terminate(_ app: NSRunningApplication) throws {
        app.terminate()
        let deadline = Date().addingTimeInterval(10)
        while !app.isTerminated && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if !app.isTerminated { app.forceTerminate() }
    }

    private struct AppBuildMissing: Error, CustomStringConvertible {
        let path: String
        var description: String { "Нет сборки приложения рядом с тестами: \(path)" }
    }

    private struct AppLaunchFailed: Error {}

    private struct LaunchReport: Decodable {
        let launchSeconds: Double
        let editorReadyAt: Double
        let idleMemoryBytes: UInt64?
    }

    /// Ждать, пока приложение допишет отчёт с памятью в покое.
    private static func waitForReport(at url: URL, timeout: TimeInterval) throws -> LaunchReport {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let report = try? JSONDecoder().decode(LaunchReport.self, from: data),
               report.idleMemoryBytes != nil {
                return report
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        throw LaunchReportMissing(path: url.path, timeout: timeout)
    }

    private struct LaunchReportMissing: Error, CustomStringConvertible {
        let path: String
        let timeout: TimeInterval
        var description: String { "Приложение не записало отчёт о запуске за \(Int(timeout)) с: \(path)" }
    }
}
