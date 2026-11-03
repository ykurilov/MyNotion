import CoreGraphics
import VisualStyle

/// Вид страницы (research R2, contracts/pages-ui.md, «Вид страницы»): широкая колонка и мелкий шрифт;
/// `textZoom` — масштаб текста приложения (`PageTextZoom`), не поле страницы.
/// Черновик этапа 0 для пробы перекладки; US1 доводит шкалу до видов 002.
public struct PageLayoutSettings: Equatable, Sendable {
    public var isFullWidth: Bool
    public var isSmallText: Bool
    public var textZoom: CGFloat

    /// Мелкий шрифт: абзац 14 вместо 16, все размеры текста блоков — той же шкалой.
    public static let smallTextScale: CGFloat = 14.0 / 16.0

    public init(isFullWidth: Bool = false, isSmallText: Bool = false, textZoom: CGFloat = 1) {
        self.isFullWidth = isFullWidth
        self.isSmallText = isSmallText
        self.textZoom = textZoom
    }

    public var fontScale: CGFloat { (isSmallText ? Self.smallTextScale : 1) * textZoom }

    /// Колонка текста: обычная — 720 по центру области страницы шириной `pageWidth` (вместе с полосой прокрутки),
    /// в узком окне поля не меньше `minimumSideInset`; широкая — во всю ширину минус `minimumSideInset` с каждой стороны.
    /// `textWidth` — ширина самого текста без полосы прокрутки.
    public func column(pageWidth: CGFloat, textWidth: CGFloat) -> (left: CGFloat, width: CGFloat) {
        let inset = Metrics.Page.minimumSideInset
        let maxWidth = isFullWidth ? .greatestFiniteMagnitude : Metrics.Page.columnWidth
        let left = isFullWidth ? inset : max(inset, (pageWidth - Metrics.Page.columnWidth) / 2)
        return (left, max(0, min(maxWidth, textWidth - left - inset)))
    }
}
