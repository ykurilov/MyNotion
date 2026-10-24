import AppKit
import XCTest

enum HoverScreenshotComparison {
    /// Сколько точек в `rect` (координаты экрана) различаются на двух снимках окна.
    static func changedPixels(_ a: XCUIScreenshot, _ b: XCUIScreenshot, rect: CGRect, window: CGRect) -> Int {
        guard let left = bitmap(a.image), let right = bitmap(b.image),
              left.pixelsWide == right.pixelsWide, left.pixelsHigh == right.pixelsHigh,
              left.bitsPerSample == 8, right.bitsPerSample == 8,
              left.bitsPerPixel == right.bitsPerPixel, left.bitsPerPixel % 8 == 0 else { return -1 }
        let scale = CGFloat(left.pixelsWide) / window.width
        let x0 = max(0, Int((rect.minX - window.minX) * scale)), x1 = min(left.pixelsWide, Int((rect.maxX - window.minX) * scale))
        let y0 = max(0, Int((rect.minY - window.minY) * scale)), y1 = min(left.pixelsHigh, Int((rect.maxY - window.minY) * scale))
        guard x0 < x1, y0 < y1, let pa = left.bitmapData, let pb = right.bitmapData else { return -1 }
        let bytesPerPixel = left.bitsPerPixel / 8
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let leftOffset = y * left.bytesPerRow + x * bytesPerPixel
                let rightOffset = y * right.bytesPerRow + x * bytesPerPixel
                if (0..<bytesPerPixel).contains(where: { abs(Int(pa[leftOffset + $0]) - Int(pb[rightOffset + $0])) > 8 }) {
                    count += 1
                }
            }
        }
        return count
    }

    private static func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // Сохраняем порядок строк исходного CGImage. Повторное рисование через NSGraphicsContext
        // может перевернуть изображение относительно экранных координат сравниваемой области.
        return NSBitmapImageRep(cgImage: cg)
    }
}
