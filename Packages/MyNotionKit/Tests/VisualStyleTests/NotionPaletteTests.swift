import AppKit
import Testing
@testable import VisualStyle

/// Цвета текста и фона Notion в светлой и тёмной теме (FR-112; contracts/blocks-and-keys.md, «Цвета»).
@Suite("Палитра цветов Notion")
struct NotionPaletteTests {
    private static let table: [(NotionTone, text: (String, String), background: (String, String))] = [
        (.gray, ("787774", "9B9B9B"), ("F1F1EF", "2F2F2F")),
        (.brown, ("9F6B53", "BA856F"), ("F4EEEE", "4A3228")),
        (.orange, ("D9730D", "C77D48"), ("FBECDD", "5C3B23")),
        (.yellow, ("CB912F", "CA9849"), ("FBF3DB", "564328")),
        (.green, ("448361", "529E72"), ("EDF3EC", "243D30")),
        (.blue, ("337EA9", "379AD3"), ("E7F3F8", "143A4E")),
        (.purple, ("9065B0", "9D68D3"), ("F6F3F9", "3C2D49")),
        (.pink, ("C14C8A", "D15796"), ("FAF1F5", "4E2C3C")),
        (.red, ("D44C47", "DF5452"), ("FDEBEC", "522E2A")),
    ]

    @Test("Девять цветов: текст и фон в обеих темах совпадают с таблицей")
    func valuesMatchTable() throws {
        for row in Self.table {
            #expect(try hex(Palette.notionText(row.0), in: .aqua) == row.text.0, "текст \(row.0), светлая")
            #expect(try hex(Palette.notionText(row.0), in: .darkAqua) == row.text.1, "текст \(row.0), тёмная")
            #expect(try hex(#require(Palette.notionBackground(row.0)), in: .aqua) == row.background.0, "фон \(row.0), светлая")
            #expect(try hex(#require(Palette.notionBackground(row.0)), in: .darkAqua) == row.background.1, "фон \(row.0), тёмная")
        }
    }

    @Test("Все девять цветов описаны")
    func tableCoversEveryTone() {
        #expect(Set(Self.table.map(\.0)) == Set(NotionTone.allCases))
        #expect(NotionTone.allCases.count == 9)
    }

    @Test("Цвет по умолчанию: текст — основной цвет страницы, фона нет")
    func defaultColor() throws {
        #expect(try hex(Palette.notionText(nil), in: .aqua) == "2C2C2B")
        #expect(try hex(Palette.notionText(nil), in: .darkAqua) == "F0EFED")
        #expect(Palette.notionBackground(nil) == nil)
    }

    @Test("Цвета меняются вместе с темой, без перекраски текста")
    func colorsAreDynamic() throws {
        let color = Palette.notionText(.red)
        #expect(try hex(color, in: .aqua) != hex(color, in: .darkAqua))
    }

    private func hex(_ color: NSColor, in appearanceName: NSAppearance.Name) throws -> String {
        let appearance = try #require(NSAppearance(named: appearanceName))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        let rgb = try #require(resolved)
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { String(format: "%02X", Int(($0 * 255).rounded())) }
            .joined()
    }
}
