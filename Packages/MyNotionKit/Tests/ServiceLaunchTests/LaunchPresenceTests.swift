import AppKit
import SwiftUI
import Testing
import ServiceLaunch

/// Служебные запуски не забирают фокус у человека за компьютером (README, «Флаги запуска»).
@Suite("Служебный запуск в фоне")
struct LaunchPresenceTests {
    static let app = "/Applications/MyNotion.app/Contents/MacOS/MyNotion"

    @Test("Каждый служебный флаг — запуск в фоне", arguments: [
        ["--ui-gallery", "/tmp/g"],
        ["--ui-gallery", "/tmp/g", "--ui-gallery-only", "trash"],
        ["--window-snapshot", "/tmp/s.png"],
        ["--window-snapshot", "/tmp/s.png", "--hover-sidebar-row", "2"],
        ["--hover-sidebar-row", "2"],
        ["--generate-reference-library", "/tmp/r.sqlite"],
        ["--generate-visual-sample", "--window-snapshot", "/tmp/s.png"],
        ["--database", "/tmp/r.sqlite", "--launch-report", "/tmp/l.json"],
        ["--typing-benchmark", "/tmp/t.json"],
        ["--search-benchmark", "/tmp/s.json"],
        ["--export-markdown", "/tmp/out"],
        ["--database", "/tmp/r.sqlite", "--export-markdown", "/tmp/out"],
    ])
    func serviceFlagsRunInBackground(flags: [String]) {
        #expect(LaunchPresence(arguments: [Self.app] + flags) == .background)
    }

    @Test("Запуск человеком — как раньше, даже с базой, темой или образцом", arguments: [
        [],
        ["--database", "/tmp/r.sqlite"],
        ["--appearance", "dark"],
        ["--generate-visual-sample"],
    ])
    func userLaunchStaysInForeground(flags: [String]) {
        #expect(LaunchPresence(arguments: [Self.app] + flags) == .foreground)
    }

    @Test("Путь после флага — не флаг: папка с именем флага не делает запуск служебным")
    func valueIsNotFlag() {
        #expect(LaunchPresence(arguments: [Self.app, "--database", "--ui-gallery"]) == .foreground)
    }

    @Test("В фоне — ни значка в Dock, ни активации, окна за всеми окнами")
    func backgroundNeverTakesFocus() {
        #expect(LaunchPresence.background.activationPolicy == .prohibited)
        #expect(LaunchPresence.background.windowLevel == .desktop)
    }

    @Test("Запуск человеком — обычное приложение с окном впереди")
    func foregroundIsRegularApp() {
        #expect(LaunchPresence.foreground.activationPolicy == .regular)
        #expect(LaunchPresence.foreground.windowLevel == .automatic)
    }
}
