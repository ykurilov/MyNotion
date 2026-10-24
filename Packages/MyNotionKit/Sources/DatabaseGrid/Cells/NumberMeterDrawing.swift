import AppKit
import Databases
import VisualStyle

/// «Показывать как» числа в ячейке (`notion-number-show-as-bar.png`): полоса — число слева, полоса справа до края ячейки;
/// кольцо — кольцо 16 точек и число справа от него. Цвет — точка цвета статуса (насыщенный цвет Notion), дорожка — бледная.
@MainActor
enum NumberMeterDrawing {
    static let ringSide: CGFloat = 16
    static let barHeight: CGFloat = 4

    static func draw(_ meter: CellPresentation.NumberMeter, in inner: CGRect, cellRect: CGRect, text: GridTextRenderer, context: CGContext) {
        let color = CellChipStyles.statusDot(meter.color).cgColor
        let track = Palette.switchOff.cgColor
        if meter.isRing {
            let ring = CGRect(x: inner.minX, y: cellRect.midY - ringSide / 2, width: ringSide, height: ringSide).insetBy(dx: 1.5, dy: 1.5)
            context.saveGState()
            context.setLineWidth(3)
            context.setStrokeColor(track)
            context.strokeEllipse(in: ring)
            if meter.fraction > 0 {
                context.setStrokeColor(color)
                context.setLineCap(.round)
                // Вид перевёрнут: от «12 часов» по часовой стрелке.
                let start = -CGFloat.pi / 2
                context.addArc(center: CGPoint(x: ring.midX, y: ring.midY), radius: ring.width / 2, startAngle: start,
                               endAngle: start + 2 * .pi * meter.fraction, clockwise: false)
                context.strokePath()
            }
            context.restoreGState()
            if let number = meter.text {
                text.draw(number, in: CGRect(x: ring.maxX + 8, y: cellRect.minY, width: inner.maxX - ring.maxX - 8, height: cellRect.height),
                          color: Palette.textPrimary, alignment: .left, context: context)
            }
            return
        }
        var barRect = inner
        if let number = meter.text {
            let width = min(text.width(number, size: Metrics.DatabaseGrid.fontSize), inner.width / 2)
            text.draw(number, in: CGRect(x: inner.minX, y: cellRect.minY, width: width + 1, height: cellRect.height), color: Palette.textPrimary,
                      alignment: .left, context: context)
            barRect.origin.x += width + 10
            barRect.size.width -= width + 10
        }
        guard barRect.width > 8 else { return }
        let bar = CGRect(x: barRect.minX, y: cellRect.midY - barHeight / 2, width: barRect.width, height: barHeight)
        context.saveGState()
        context.setFillColor(track)
        context.addPath(CGPath(roundedRect: bar, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
        context.fillPath()
        if meter.fraction > 0 {
            let filled = CGRect(x: bar.minX, y: bar.minY, width: max(barHeight, bar.width * meter.fraction), height: barHeight)
            context.setFillColor(color)
            context.addPath(CGPath(roundedRect: filled, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
            context.fillPath()
        }
        context.restoreGState()
    }
}
