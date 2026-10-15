import AppKit

/// Значок страницы без иконки, как в Notion: лист с загнутым правым верхним углом, тонкой линией.
/// Рисуется вектором и сам перекрашивается вместе с темой Mac.
public enum DocumentGlyph {
    /// Квадрат `size` × `size`; лист занимает его середину.
    public static func image(size: CGFloat, color: NSColor = Palette.sidebarText) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let sheetWidth = rect.width * 0.62
            let sheetHeight = rect.height * 0.78
            let left = rect.midX - sheetWidth / 2
            let top = rect.midY - sheetHeight / 2
            let fold = sheetWidth * 0.38
            let lineWidth = max(1, rect.width / 16)

            let sheet = NSBezierPath()
            sheet.move(to: NSPoint(x: left, y: top))
            sheet.line(to: NSPoint(x: left + sheetWidth - fold, y: top))
            sheet.line(to: NSPoint(x: left + sheetWidth, y: top + fold))
            sheet.line(to: NSPoint(x: left + sheetWidth, y: top + sheetHeight))
            sheet.line(to: NSPoint(x: left, y: top + sheetHeight))
            sheet.close()
            // Загиб угла.
            sheet.move(to: NSPoint(x: left + sheetWidth - fold, y: top))
            sheet.line(to: NSPoint(x: left + sheetWidth - fold, y: top + fold))
            sheet.line(to: NSPoint(x: left + sheetWidth, y: top + fold))

            sheet.lineWidth = lineWidth
            sheet.lineJoinStyle = .round
            sheet.lineCapStyle = .round
            color.setStroke()
            sheet.stroke()
            return true
        }
        image.accessibilityDescription = "Страница"
        return image
    }
}
