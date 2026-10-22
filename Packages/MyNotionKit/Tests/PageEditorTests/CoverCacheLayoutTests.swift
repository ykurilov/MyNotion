import AppKit
import Testing
@testable import PageEditor

@MainActor
@Suite("Обложка: уже нарисованный текст после изменения отступа")
struct CoverCacheLayoutTests {
    @Test("Добавление обложки и сужение не оставляют буквы поверх изображения", arguments: [false, true])
    func renderedTextMovesBelowCover(icon: Bool) throws {
        let editor = try EditorFixture([.heading(2, "Заголовок блока"), .paragraph("Текст под заголовком."), .bullet("Пункт")],
                                       icon: icon ? "🥰" : nil)
        let view = editor.textView
        _ = try ViewPixels(view, appearance: .aqua) // Сначала TextKit уже нарисовал страницу без обложки.
        let cover = SolidCoverProbeView()
        view.setCover(cover, height: 280)
        for width in [CGFloat(1200), 900, 1200] {
            editor.window.setContentSize(NSSize(width: width, height: 800))
            view.frame.size.width = width
            let pixels = try ViewPixels(view, appearance: .aqua, rect: cover.frame)
            let iconRect = view.header.convert(view.header.iconView.frame, to: view).insetBy(dx: -4, dy: -4)
            var dark = 0
            for y in stride(from: 4.0, to: 276, by: 3) {
                for x in stride(from: 4.0, to: Double(width - 4), by: 3) {
                    let point = CGPoint(x: x, y: y)
                    if icon && iconRect.contains(point) { continue }
                    let color = pixels.color(at: point, over: (1, 1, 1))
                    if color.red < 0.18 && color.green < 0.18 && color.blue < 0.18 { dark += 1 }
                }
            }
            print("Обложка cache icon=\(icon) width=\(width) dark=\(dark) origin=\(view.textContainerOrigin)")
            if let path = ProcessInfo.processInfo.environment["MYNOTION_COVER_PROBE_DIR"] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                let data = try #require(pixels.bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: path).appendingPathComponent("cover-\(icon)-\(Int(width)).png"))
            }
            #expect(dark <= 4, "Текст остался на обложке после изменения inset: icon=\(icon), width=\(width), dark=\(dark)")
            let title = view.header.convert(view.header.titleField.frame, to: view)
            #expect(title.minY >= cover.frame.maxY)
        }
    }
}

@MainActor
private final class SolidCoverProbeView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.65, green: 0.8, blue: 0.95, alpha: 1).setFill()
        bounds.fill()
    }
}
