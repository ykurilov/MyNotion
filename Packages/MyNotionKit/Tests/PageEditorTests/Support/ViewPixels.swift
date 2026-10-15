import AppKit
import Testing

/// Снимок вида в заданной теме и замеры по пикселям: цвет точки и рамка «чернил» (всего, что нарисовано).
/// Координаты — в точках вида, как у его `bounds`.
@MainActor
struct ViewPixels {
    let view: NSView
    let bitmap: NSBitmapImageRep

    init(_ view: NSView, appearance: NSAppearance.Name, rect: NSRect? = nil) throws {
        self.view = view
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        let rect = rect ?? view.bounds
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        self.bitmap = bitmap
        self.rect = rect
    }

    private let rect: NSRect
    private var scale: CGFloat { CGFloat(bitmap.pixelsWide) / rect.width }

    /// Цвет точки, наложенный на `background`: у прозрачных мест вида — цвет фона.
    func color(at point: NSPoint, over base: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let pixel = self.pixel(at: point)
        let alpha = pixel.alpha
        return (pixel.red * alpha + base.red * (1 - alpha),
                pixel.green * alpha + base.green * (1 - alpha),
                pixel.blue * alpha + base.blue * (1 - alpha))
    }

    /// Рамка нарисованного внутри `area`: точки, где непрозрачность выше `threshold`. В точках вида.
    func inkBounds(in area: NSRect, threshold: CGFloat = 0.3) -> NSRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        let (columns, rows) = pixelRange(of: area)
        for row in rows {
            for column in columns where alphaAt(column: column, row: row) > threshold {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard minX <= maxX else { return nil }
        return pointRect(columns: minX...maxX, rows: minY...maxY)
    }

    /// Рамка нарисованного поверх сплошного фона `background` внутри `area`: точки, цвет которых отличается от фона
    /// больше чем на `threshold`. Для видов, которые сами заливают фон.
    func inkBounds(in area: NSRect, over background: (red: CGFloat, green: CGFloat, blue: CGFloat), threshold: CGFloat = 0.15) -> NSRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        let (columns, rows) = pixelRange(of: area)
        for row in rows {
            for column in columns {
                guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB),
                      colorDistance((color.redComponent, color.greenComponent, color.blueComponent), background) > threshold else { continue }
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard minX <= maxX else { return nil }
        return pointRect(columns: minX...maxX, rows: minY...maxY)
    }

    /// Самый далёкий от фона цвет внутри `area`: цвет штрихов без сглаженных краёв.
    func strongestInkColor(in area: NSRect, over background: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        var best: (red: CGFloat, green: CGFloat, blue: CGFloat)?
        var bestDistance: CGFloat = 0
        let (columns, rows) = pixelRange(of: area)
        for row in rows {
            for column in columns {
                guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                let value = (red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
                let distance = colorDistance(value, background)
                if distance > bestDistance { bestDistance = distance; best = value }
            }
        }
        return best
    }

    /// Средний цвет нарисованного внутри `area`.
    func averageInkColor(in area: NSRect, threshold: CGFloat = 0.5) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        var sum = (red: CGFloat(0), green: CGFloat(0), blue: CGFloat(0)), count: CGFloat = 0
        let (columns, rows) = pixelRange(of: area)
        for row in rows {
            for column in columns {
                guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB), color.alphaComponent > threshold else { continue }
                sum.red += color.redComponent; sum.green += color.greenComponent; sum.blue += color.blueComponent
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (sum.red / count, sum.green / count, sum.blue / count)
    }

    // MARK: Пиксели

    private func pixel(at point: NSPoint) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let column = Int(((point.x - rect.minX) * scale).rounded(.down))
        let row = rowIndex(forY: point.y)
        guard let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
        return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }

    private func alphaAt(column: Int, row: Int) -> CGFloat {
        bitmap.colorAt(x: column, y: row)?.alphaComponent ?? 0
    }

    /// Строка картинки сверху вниз для координаты `y` вида.
    private func rowIndex(forY y: CGFloat) -> Int {
        let fromTop = view.isFlipped ? y - rect.minY : rect.maxY - y
        return Int((fromTop * scale).rounded(.down))
    }

    private func pixelRange(of area: NSRect) -> (ClosedRange<Int>, ClosedRange<Int>) {
        let area = area.intersection(rect)
        let left = max(0, Int(((area.minX - rect.minX) * scale).rounded(.down)))
        let right = min(bitmap.pixelsWide - 1, Int(((area.maxX - rect.minX) * scale).rounded(.up)) - 1)
        let top = view.isFlipped ? area.minY - rect.minY : rect.maxY - area.maxY
        let bottom = top + area.height
        let first = max(0, Int((top * scale).rounded(.down)))
        let last = min(bitmap.pixelsHigh - 1, Int((bottom * scale).rounded(.up)) - 1)
        return (left...max(left, right), first...max(first, last))
    }

    private func pointRect(columns: ClosedRange<Int>, rows: ClosedRange<Int>) -> NSRect {
        let x = rect.minX + CGFloat(columns.lowerBound) / scale
        let width = CGFloat(columns.count) / scale
        let height = CGFloat(rows.count) / scale
        let top = CGFloat(rows.lowerBound) / scale
        let y = view.isFlipped ? rect.minY + top : rect.maxY - top - height
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

extension NSColor {
    /// Цвет в теме `appearance` в sRGB.
    func resolved(in appearance: NSAppearance.Name) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var color = self
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            color = self.usingColorSpace(.sRGB) ?? self
        }
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }
}

/// Насколько различаются два цвета: наибольшая разница по каналам, 0…1.
func colorDistance(_ a: (red: CGFloat, green: CGFloat, blue: CGFloat), _ b: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> CGFloat {
    max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
}
