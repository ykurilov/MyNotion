import AppKit
import Testing
@testable import VisualStyle

@Suite("Цвета светлой и тёмной темы")
struct PaletteTests {
    @Test("Цвет текста и фона страницы меняются вместе с темой Mac")
    func colorsFollowSystemAppearance() throws {
        #expect(try hex(Palette.textPrimary, in: .aqua) == "2C2C2B")
        #expect(try hex(Palette.textPrimary, in: .darkAqua) == "F0EFED")
        #expect(try hex(Palette.pageBackground, in: .aqua) == "FFFFFF")
        #expect(try hex(Palette.pageBackground, in: .darkAqua) == "191919")
    }

    private func hex(_ color: NSColor, in appearanceName: NSAppearance.Name) throws -> String {
        let appearance = try #require(NSAppearance(named: appearanceName))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        let rgb = try #require(resolved)
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { String(format: "%02X", Int(($0 * 255).rounded())) }
            .joined()
    }
}

@Suite("Маркеры и номера списков")
struct ListMarkersTests {
    @Test("Маркеры по уровням: • → ◦ → ▪, дальше по кругу")
    func bulletsByLevel() {
        #expect((0...4).map(ListMarkers.bullet(atIndent:)) == ["•", "◦", "▪", "•", "◦"])
    }

    @Test("Номера по уровням: 1. → a. → i., дальше по кругу")
    func numbersByLevel() {
        #expect(ListMarkers.number(3, atIndent: 0) == "3.")
        #expect(ListMarkers.number(1, atIndent: 1) == "a.")
        #expect(ListMarkers.number(26, atIndent: 1) == "z.")
        #expect(ListMarkers.number(27, atIndent: 1) == "aa.")
        #expect(ListMarkers.number(4, atIndent: 2) == "iv.")
        #expect(ListMarkers.number(14, atIndent: 2) == "xiv.")
        #expect(ListMarkers.number(2, atIndent: 3) == "2.")
    }
}
