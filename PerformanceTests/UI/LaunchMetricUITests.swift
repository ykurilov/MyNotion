import XCTest

/// Запуск глазами XCTest: до готовности приложения отвечать на события (сборка Release, эталонная база).
/// Цифры для сравнения между сборками; бюджет проверяет `LaunchAndMemoryTests`.
final class LaunchMetricUITests: XCTestCase {
    @MainActor
    func testLaunchMetric() throws {
        let library = try ReferenceLibrary.url()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            let app = XCUIApplication()
            app.launchArguments = ["--database", library.path]
            app.launch()
            app.terminate()
        }
    }
}
