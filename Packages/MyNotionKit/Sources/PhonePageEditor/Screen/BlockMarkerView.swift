#if canImport(UIKit)
import UIKit
import VisualStyle

/// Колонка слева от текста пункта: точка, номер, квадрат чекбокса или треугольник переключателя.
/// Чекбокс и треугольник нажимаются — касание приходит как `.primaryActionTriggered`.
final class BlockMarkerView: UIControl {
    enum Mark: Equatable {
        case none
        case bullet(indent: Int)
        case number(String)
        case checkbox(checked: Bool)
        case toggle(expanded: Bool)
    }

    var mark: Mark = .none {
        didSet { if mark != oldValue { updateLook() } }
    }

    /// Высота первой строки текста: маркер стоит по её середине.
    var lineHeight: CGFloat = 24 {
        didSet { if lineHeight != oldValue { setNeedsDisplay() } }
    }

    private let numberLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        numberLabel.font = TextLook.paragraph.font
        numberLabel.textColor = PhonePalette.textPrimary
        numberLabel.textAlignment = .center
        numberLabel.adjustsFontSizeToFitWidth = true
        numberLabel.minimumScaleFactor = 0.6
        addSubview(numberLabel)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: BlockMarkerView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func layoutSubviews() {
        super.layoutSubviews()
        numberLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: lineHeight)
    }

    /// Палец толще квадрата 16 pt: касание ловится с запасом вокруг.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isEnabled else { return false }
        return bounds.insetBy(dx: -10, dy: -10).contains(point)
    }

    private func updateLook() {
        if case .number(let label) = mark {
            numberLabel.text = label
            numberLabel.isHidden = false
        } else {
            numberLabel.isHidden = true
        }
        switch mark {
        case .checkbox:
            isEnabled = true
            accessibilityTraits = .button
            accessibilityLabel = "Отметить задачу"
        case .toggle(let expanded):
            isEnabled = true
            accessibilityTraits = .button
            accessibilityLabel = expanded ? "Свернуть" : "Раскрыть"
        default:
            isEnabled = false
            accessibilityLabel = nil
        }
        isAccessibilityElement = isEnabled
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let center = CGPoint(x: bounds.midX, y: lineHeight / 2)
        switch mark {
        case .none, .number:
            break
        case .bullet(let indent):
            drawBullet(ListMarkers.bullet(atIndent: indent), at: center)
        case .checkbox(let checked):
            drawCheckbox(checked: checked, at: center)
        case .toggle(let expanded):
            drawTriangle(expanded: expanded, at: center)
        }
    }

    /// `•`, `◦`, `▪` — рисунком одного видимого размера, как маркеры Mac.
    private func drawBullet(_ glyph: String, at center: CGPoint) {
        let color = PhonePalette.textPrimary
        let diameter: CGFloat = 6
        let box = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        switch glyph {
        case "◦":
            let ring = UIBezierPath(ovalIn: box.insetBy(dx: Metrics.BlockMarker.hollowBulletLineWidth / 2,
                                                        dy: Metrics.BlockMarker.hollowBulletLineWidth / 2))
            ring.lineWidth = Metrics.BlockMarker.hollowBulletLineWidth
            color.setStroke()
            ring.stroke()
        case "▪":
            color.setFill()
            UIBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).fill()
        default:
            color.setFill()
            UIBezierPath(ovalIn: box).fill()
        }
    }

    private func drawCheckbox(checked: Bool, at center: CGPoint) {
        let size = Metrics.Checkbox.size
        let box = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        if checked {
            PhonePalette.checkboxChecked.setFill()
            UIBezierPath(roundedRect: box, cornerRadius: Metrics.Checkbox.cornerRadius).fill()
            let tick = UIBezierPath()
            tick.move(to: CGPoint(x: box.minX + size * 0.24, y: box.minY + size * 0.52))
            tick.addLine(to: CGPoint(x: box.minX + size * 0.42, y: box.minY + size * 0.70))
            tick.addLine(to: CGPoint(x: box.minX + size * 0.77, y: box.minY + size * 0.32))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            PhonePalette.checkboxCheckmark.setStroke()
            tick.stroke()
        } else {
            let inset = Metrics.Checkbox.borderWidth / 2
            let border = UIBezierPath(roundedRect: box.insetBy(dx: inset, dy: inset), cornerRadius: Metrics.Checkbox.cornerRadius)
            border.lineWidth = Metrics.Checkbox.borderWidth
            PhonePalette.textPrimary.setStroke()
            border.stroke()
        }
    }

    private func drawTriangle(expanded: Bool, at center: CGPoint) {
        let width = Metrics.Toggle.triangleWidth
        let height = Metrics.Toggle.triangleHeight
        let path = UIBezierPath()
        if expanded {
            path.move(to: CGPoint(x: center.x - height / 2, y: center.y - width / 2))
            path.addLine(to: CGPoint(x: center.x + height / 2, y: center.y - width / 2))
            path.addLine(to: CGPoint(x: center.x, y: center.y + width / 2))
        } else {
            path.move(to: CGPoint(x: center.x - width / 2, y: center.y - height / 2))
            path.addLine(to: CGPoint(x: center.x + width / 2, y: center.y))
            path.addLine(to: CGPoint(x: center.x - width / 2, y: center.y + height / 2))
        }
        path.close()
        PhonePalette.textPrimary.setFill()
        path.fill()
    }
}
#endif
