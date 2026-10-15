import CoreGraphics

/// Цель снимка в окне — блок под мышью, курсор, выделение, строка дерева, меню (ui-review 2026-10-15-round2, №25).
/// Галерея прокручивает к цели, а цель за краем окна делает состояние не снятым: такой снимок ничего не проверяет.
public enum GalleryViewport {
    /// Начало прокрутки, при котором цель посередине видимой высоты, в пределах документа. Ось — сверху вниз.
    public static func scrollOffset(centering target: CGRect, visibleHeight: CGFloat, documentHeight: CGFloat) -> CGFloat {
        let centered = target.midY - visibleHeight / 2
        return min(max(0, centered), max(0, documentHeight - visibleHeight))
    }

    /// Причина «Не снято»: цели нет или она не целиком в видимой части. `nil` — снимать можно.
    public static func problem(_ name: String, at target: CGRect?, visible: CGRect) -> String? {
        guard let target else { return "цель не найдена: \(name)" }
        if visible.insetBy(dx: -tolerance, dy: -tolerance).contains(target) { return nil }
        return "цель вне окна: \(name) \(describe(target)), видно \(describe(visible))"
    }

    /// Доли точки от пересчёта координат — не выход за край.
    private static let tolerance: CGFloat = 0.5

    private static func describe(_ rect: CGRect) -> String {
        "x \(Int(rect.minX.rounded()))…\(Int(rect.maxX.rounded())), y \(Int(rect.minY.rounded()))…\(Int(rect.maxY.rounded()))"
    }
}
