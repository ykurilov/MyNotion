import AppKit
import Testing
import VisualStyle

/// Значок страницы без иконки как в Notion для Mac (снимок Юрия 15.10.2026, строка «Документы» слева):
/// лист ≈ 27×36 точек экрана на 22 пункта значка, скруглённые углы, загиб ≈ половины ширины, внутри
/// в нижней части две строчки текста ≈ 0,6 ширины листа по середине.
@MainActor
@Suite("Значок страницы без иконки")
struct DocumentGlyphTests {
    static let size: CGFloat = 22
    static let scale: CGFloat = 4

    /// Краска значка по пикселям: `true` — закрашено заметно.
    private func ink() throws -> (rows: Int, columns: Int, at: (Int, Int) -> Bool) {
        let side = Int(Self.size * Self.scale)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: Self.size, height: Self.size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        DocumentGlyph.image(size: Self.size, color: .black).draw(in: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        NSGraphicsContext.restoreGraphicsState()
        // Строки сверху вниз.
        return (side, side, { x, y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 })
    }

    @Test("Лист пропорций Notion, со скруглёнными углами")
    func sheetShape() throws {
        let (rows, columns, at) = try ink()
        let inkedColumns = (0..<columns).filter { x in (0..<rows).contains { at(x, $0) } }
        let inkedRows = (0..<rows).filter { y in (0..<columns).contains { at($0, y) } }
        let left = try #require(inkedColumns.first), right = try #require(inkedColumns.last)
        let top = try #require(inkedRows.first), bottom = try #require(inkedRows.last)
        let width = CGFloat(right - left + 1) / Self.scale, height = CGFloat(bottom - top + 1) / Self.scale
        // У Notion 27×36 пикселей при ×1,91: ≈ 14,1 × 18,8.
        #expect(abs(width - 14.1) <= 0.75 && abs(height - 18.8) <= 0.75, "Лист \(width)×\(height), у Notion ≈ 14,1×18,8")
        // Полпункта внутрь от угла рамки: у скруглённого угла пусто, у острого — край листа.
        let inset = Int(Self.scale / 2)
        #expect(!at(left + inset, bottom - inset) && !at(right - inset, bottom - inset) && !at(left + inset, top + inset),
                "Углы листа острые, у Notion скруглены")
    }

    @Test("Внутри листа — две строчки текста в нижней части, по середине")
    func textLines() throws {
        let (rows, columns, at) = try ink()
        let inkedColumns = (0..<columns).filter { x in (0..<rows).contains { at(x, $0) } }
        let left = try #require(inkedColumns.first), right = try #require(inkedColumns.last)
        let middle = (left + right) / 2
        // Полосы краски по середине листа между боковыми краями: верхний край, загиб, строчки, нижний край.
        var stripes: [ClosedRange<Int>] = []
        for y in 0..<rows where at(middle, y) {
            if let last = stripes.last, last.upperBound == y - 1 { stripes[stripes.count - 1] = last.lowerBound...y } else { stripes.append(y...y) }
        }
        let inkedRows = (0..<rows).filter { y in (0..<columns).contains { at($0, y) } }
        let top = try #require(inkedRows.first), bottom = try #require(inkedRows.last)
        let lines = stripes.filter { $0.lowerBound > top + (bottom - top) / 2 && $0.upperBound < bottom - 4 }
        try #require(lines.count == 2, "Строчек внутри листа \(lines.count): \(stripes)")
        for line in lines {
            let y = (line.lowerBound + line.upperBound) / 2
            let span = (left...right).filter { at($0, y) }
            // Строчка не касается боковых краёв листа: ищем отрезок вокруг середины.
            var start = middle, end = middle
            while start - 1 > left, at(start - 1, y) { start -= 1 }
            while end + 1 < right, at(end + 1, y) { end += 1 }
            let share = CGFloat(end - start + 1) / CGFloat(right - left + 1)
            #expect(abs(share - 0.6) <= 0.1, "Строчка \(share) ширины листа, у Notion ≈ 0,6; закрашено \(span.count)")
            #expect(abs(CGFloat(start - left) - CGFloat(right - end)) <= Self.scale, "Строчка не по середине: \(start)…\(end) в \(left)…\(right)")
        }
    }
}
