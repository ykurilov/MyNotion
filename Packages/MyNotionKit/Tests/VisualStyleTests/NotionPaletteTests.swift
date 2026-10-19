import AppKit
import Testing
@testable import VisualStyle

/// Цвета текста и фона Notion в светлой и тёмной теме (FR-112; contracts/blocks-and-keys.md, «Цвета»).
@Suite("Палитра цветов Notion")
struct NotionPaletteTests {
    /// Значения сняты с живого Notion 7.39.0 (пиксели снимков экрана, обе темы): текст в обеих темах один и тот же.
    private static let table: [(NotionTone, text: String, background: (String, String))] = [
        (.gray, "7D7A75", ("F0EFED", "383836")),
        (.brown, "9F765A", ("F5EDE9", "45362D")),
        (.orange, "D27B2D", ("FBEBDE", "53361F")),
        (.yellow, "CB9434", ("F9F3DC", "504425")),
        (.green, "50946E", ("E8F1EC", "263D30")),
        (.blue, "387DC9", ("E5F2FC", "233850")),
        (.purple, "9A6BB4", ("F3EBF9", "3C2D47")),
        (.pink, "C14C8A", ("FAE9F1", "4E2B3C")),
        (.red, "CF5148", ("FCE9E7", "502C29")),
    ]

    @Test("Девять цветов: текст и фон в обеих темах совпадают с таблицей")
    func valuesMatchTable() throws {
        for row in Self.table {
            #expect(try hex(Palette.notionText(row.0), in: .aqua) == row.text, "текст \(row.0), светлая")
            #expect(try hex(Palette.notionText(row.0), in: .darkAqua) == row.text, "текст \(row.0), тёмная")
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

    @Test("Фон меняется вместе с темой")
    func backgroundIsDynamic() throws {
        let color = try #require(Palette.notionBackground(.red))
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
