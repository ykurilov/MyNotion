import AppKit

/// Значок базы без иконки, как у таблицы Notion: скруглённая рамка, строка шапки и столбец слева, тонкой линией.
/// Рисуется вектором и перекрашивается вместе с темой Mac (≈ по снимку Notion, уточняет US1).
public enum DatabaseGlyph {
    public static func image(size: CGFloat, color: NSColor = Palette.sidebarIcon) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let lineWidth = max(1, rect.width / 16)
            let frame = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.2)
            let path = NSBezierPath(roundedRect: frame, xRadius: rect.width * 0.08, yRadius: rect.width * 0.08)
            let header = frame.minY + frame.height * 0.36
            path.move(to: NSPoint(x: frame.minX, y: header))
            path.line(to: NSPoint(x: frame.maxX, y: header))
            let column = frame.minX + frame.width * 0.38
            path.move(to: NSPoint(x: column, y: header))
            path.line(to: NSPoint(x: column, y: frame.maxY))
            path.lineWidth = lineWidth
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
            return true
        }
        image.accessibilityDescription = "База данных"
        return image
    }
}
