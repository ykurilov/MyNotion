import Testing
@testable import PageVersions

/// Модуль собран и подключён (этап 0); проверки поведения пишет своя история.
@Suite("PageVersions: модуль")
struct PageVersionsModuleTests {
    @Test("Модуль подключается")
    func moduleLinks() {}
}
