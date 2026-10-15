import AppKit
import CoreText
import Testing
@testable import PageEditor
import VisualStyle

/// Путь в верхней полосе как у Notion (снимок Юрия 15.10.2026): «/» тусклый, от названия до «/» ≈ 7,5, от «/» до названия ≈ 8,5.
@MainActor
@Suite("Вид пути в верхней полосе")
struct BreadcrumbLookTests {
    static let path = "Родитель / Страница"

    @Test("«/» тусклый, названия цвета текста")
    func separatorIsDim() throws {
        let text = BreadcrumbText.attributed(Self.path)
        let slash = (text.string as NSString).range(of: "/")
        #expect(text.attribute(.foregroundColor, at: slash.location, effectiveRange: nil) as? NSColor == Palette.breadcrumbSeparator)
        #expect(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Palette.textPrimary)
        #expect(text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? NSColor == Palette.textPrimary)
    }

    @Test("Просветы у «/» как у Notion: ≈ 7,5 до и ≈ 8,5 после — по рисункам букв")
    func separatorSpacing() throws {
        let text = BreadcrumbText.attributed(Self.path)
        let slash = (text.string as NSString).range(of: "/").location
        let ink = inkBounds(of: text)
        let before = try #require(ink[slash - 2]), mark = try #require(ink[slash]), after = try #require(ink[slash + 2])
        let gaps = (mark.minX - before.maxX, after.minX - mark.maxX)
        #expect(abs(gaps.0 - 7.5) <= 0.75 && abs(gaps.1 - 8.5) <= 0.75, "Просветы у «/» \(gaps), у Notion 7,5 и 8,5")
        #expect(BreadcrumbText.measure(Self.path) == Double(text.size().width), "Ширина для обрезки пути — по тому же виду")
    }

    /// Рисунок каждой буквы строки по месту, где её ставит CoreText.
    private func inkBounds(of text: NSAttributedString) -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        let line = CTLineCreateWithAttributedString(text)
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            for glyph in 0..<count {
                let bounds = CTRunGetImageBounds(run, nil, CFRange(location: glyph, length: 1))
                if !bounds.isNull, bounds.width > 0 { result[indices[glyph]] = bounds }
            }
        }
        return result
    }
}
