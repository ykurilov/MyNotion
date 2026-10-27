#if canImport(AppKit)
import AppKit

/// Значок страницы без иконки, как в Notion для Mac: лист со скруглёнными углами, загнутым правым верхним углом
/// и двумя строчками текста в нижней части, тонкой линией. Рисуется вектором и сам перекрашивается вместе с темой Mac.
/// Доли — по снимку Notion 15.10.2026 (лист ≈ 14 × 19 на значке 22).
public enum DocumentGlyph {
    /// Квадрат `size` × `size`; лист занимает его середину.
    public static func image(size: CGFloat, color: NSColor = Palette.sidebarIcon) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let sheetWidth = rect.width * 0.58
            let sheetHeight = rect.height * 0.79
            let left = rect.midX - sheetWidth / 2
            let top = rect.midY - sheetHeight / 2
            let right = left + sheetWidth
            let bottom = top + sheetHeight
            let fold = sheetWidth * 0.48
            let radius = rect.width * 0.07
            let lineWidth = max(1, rect.width / 16)

            let sheet = NSBezierPath()
            sheet.move(to: NSPoint(x: left + radius, y: top))
            sheet.line(to: NSPoint(x: right - fold, y: top))
            sheet.line(to: NSPoint(x: right, y: top + fold))
            sheet.appendArc(from: NSPoint(x: right, y: bottom), to: NSPoint(x: left, y: bottom), radius: radius)
            sheet.appendArc(from: NSPoint(x: left, y: bottom), to: NSPoint(x: left, y: top), radius: radius)
            sheet.appendArc(from: NSPoint(x: left, y: top), to: NSPoint(x: right - fold, y: top), radius: radius)
            sheet.close()
            // Загиб угла.
            sheet.move(to: NSPoint(x: right - fold, y: top))
            sheet.line(to: NSPoint(x: right - fold, y: top + fold))
            sheet.line(to: NSPoint(x: right, y: top + fold))
            // Строчки текста: ≈ 0,6 ширины листа по середине, на 0,63 и 0,79 высоты.
            let lineLength = sheetWidth * 0.6 - lineWidth
            for share in [0.63, 0.79] {
                let y = top + sheetHeight * share
                sheet.move(to: NSPoint(x: rect.midX - lineLength / 2, y: y))
                sheet.line(to: NSPoint(x: rect.midX + lineLength / 2, y: y))
            }

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
#endif
