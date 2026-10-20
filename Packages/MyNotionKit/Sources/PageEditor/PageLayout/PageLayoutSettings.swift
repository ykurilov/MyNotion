import CoreGraphics
import VisualStyle

/// Вид страницы (research R2, contracts/pages-ui.md, «Вид страницы»): широкая колонка и мелкий шрифт.
/// Черновик этапа 0 для пробы перекладки; US1 доводит шкалу до видов 002.
public struct PageLayoutSettings: Equatable, Sendable {
    public var isFullWidth: Bool
    public var isSmallText: Bool

    /// Мелкий шрифт: абзац 14 вместо 16, все размеры текста блоков — той же шкалой.
    public static let smallTextScale: CGFloat = 14.0 / 16.0

    public init(isFullWidth: Bool = false, isSmallText: Bool = false) {
        self.isFullWidth = isFullWidth
        self.isSmallText = isSmallText
    }

    public var fontScale: CGFloat { isSmallText ? Self.smallTextScale : 1 }

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
