import CoreGraphics

/// Где картинка обложки стоит в её рамке (research R1): заполняет по ширине, по вертикали видна часть по `offset`
/// (0 — верх картинки, 1 — низ, как `object-position` у Notion). Картинка ниже рамки — заполняет по высоте, по центру.
public struct CoverImagePlacement: Equatable, Sendable {
    public static func rect(imageAspect: CGFloat, in bounds: CGRect, offset: Double) -> CGRect {
        guard imageAspect > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let byWidth = CGSize(width: bounds.width, height: bounds.width / imageAspect)
        if byWidth.height >= bounds.height {
            let spare = byWidth.height - bounds.height
            return CGRect(x: bounds.minX, y: bounds.minY - spare * CGFloat(offset), width: byWidth.width, height: byWidth.height)
        }
        let width = bounds.height * imageAspect
        return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
    }
}

/// Режим «Переместить»: картинку тянут вверх-вниз, сдвиг — от того, где начали; «Сохранить положение» пишет его
/// одной правкой, «Отмена» возвращает прежний.
public struct CoverRepositionMode: Equatable, Sendable {
    /// Сдвиг до начала режима.
    public let originalOffset: Double
    /// Сдвиг сейчас, пока тянут.
    public private(set) var offset: Double
    private var dragStart: (y: CGFloat, offset: Double)?

    public init(offset: Double) {
        originalOffset = offset
        self.offset = offset
    }

    public mutating func beginDrag(atY y: CGFloat) {
        dragStart = (y, offset)
    }

    /// Указатель на `y` (координаты вниз растут): картинку тянут вниз — видна часть выше, сдвиг меньше.
    /// `spare` — насколько картинка выше рамки; не выше — двигать нечего.
    public mutating func drag(toY y: CGFloat, spare: CGFloat) {
        guard let dragStart, spare > 0 else { return }
        offset = min(max(dragStart.offset - Double((y - dragStart.y) / spare), 0), 1)
    }

    public mutating func endDrag() {
        dragStart = nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.originalOffset == rhs.originalOffset && lhs.offset == rhs.offset
    }
}
