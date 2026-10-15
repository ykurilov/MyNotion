import AppKit
import Testing
@testable import VisualStyle

@Suite("Кнопки окна — на месте Notion")
@MainActor
struct TrafficLightsTests {
    @Test("Красная кнопка — на 20,75 от левого края и 17,75 от верха; шаг системный; после изменения окна — там же")
    func buttonsStayWhereNotionHasThem() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let systemPitch = try pitch(in: window)

        TrafficLights.keepInPlace(in: window)
        try expectInPlace(window, pitch: systemPitch)

        window.setContentSize(NSSize(width: 700, height: 450))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        try expectInPlace(window, pitch: systemPitch)
    }

    /// Середина кнопки от левого верхнего угла окна.
    private func center(of type: NSWindow.ButtonType, in window: NSWindow) throws -> CGPoint {
        let button = try #require(window.standardWindowButton(type))
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        return CGPoint(x: point.x, y: window.frame.height - point.y)
    }

    private func pitch(in window: NSWindow) throws -> CGFloat {
        try center(of: .miniaturizeButton, in: window).x - center(of: .closeButton, in: window).x
    }

    private func expectInPlace(_ window: NSWindow, pitch: CGFloat) throws {
        let close = try center(of: .closeButton, in: window)
        #expect(abs(close.x - Metrics.Window.trafficLightsCenter.x) < 0.01, "красная: \(close)")
        #expect(abs(close.y - Metrics.Window.trafficLightsCenter.y) < 0.01, "красная: \(close)")
        let zoom = try center(of: .zoomButton, in: window)
        #expect(abs(zoom.x - close.x - 2 * pitch) < 0.01 && abs(zoom.y - close.y) < 0.01, "зелёная: \(zoom)")
    }
}
