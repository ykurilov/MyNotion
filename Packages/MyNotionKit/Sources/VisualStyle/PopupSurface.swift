#if canImport(AppKit)
import AppKit

/// Карточка всплывающей панели — меню «/», меню блока, окно корзины (contracts/visual-style.md, «Всплывающие меню»):
/// скругление 10, тень и рамка (`popupMenuShadow` у меню, `popupCardShadow` у окон-карточек), фон `popupMenuBackground`. Окно вокруг карточки оставляет место под тень.
public enum PopupSurface {
    @MainActor
    public static func draw(card: NSRect, shadow layers: [ShadowLayer] = Palette.popupMenuShadow) {
        let radius = Metrics.PopupMenu.cornerRadius
        let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        for layer in layers {
            NSGraphicsContext.saveGraphicsState()
            if layer.spread > 0 {
                // Слой без размытия — рамка: кольцо шире карточки на spread.
                layer.color.setFill()
                NSBezierPath(roundedRect: card.insetBy(dx: -layer.spread, dy: -layer.spread),
                             xRadius: radius + layer.spread, yRadius: radius + layer.spread).fill()
            } else {
                let shadow = NSShadow()
                // Тени — в неперевёрнутых координатах: вниз — отрицательный сдвиг.
                shadow.shadowOffset = NSSize(width: 0, height: -layer.offsetY)
                shadow.shadowBlurRadius = layer.blurRadius
                shadow.shadowColor = layer.color
                shadow.set()
                Palette.popupMenuBackground.setFill()
                path.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        Palette.popupMenuBackground.setFill()
        path.fill()
    }
}
#endif
