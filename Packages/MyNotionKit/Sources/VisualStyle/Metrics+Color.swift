import CoreGraphics

extension Metrics {
    /// Подложка цвета блока (contracts/visual-style.md, «Цвета»).
    public enum BlockBackground {
        public static let cornerRadius: CGFloat = 4
        /// Подложка выступает за строки текста: текст лежит в строке низко, снизу нужен запас больше, чем сверху.
        public static let topOutset: CGFloat = 1
        public static let bottomOutset: CGFloat = 5
    }
}

extension Metrics {
    /// Окно цветов: «Последние», «Цвет текста», «Цвет фона» (contracts/blocks-and-keys.md, «Цвета»). Строки и поля — как у меню блока.
    /// Окно цветов, как у Notion 7.39 (снимки 19.10.2026, ±1,3): разделы «Последние», «Цвет текста», «Цвет фона» —
    /// сетки по 5 образцов в ряд. Отсчёт — от левого верхнего угла карточки.
    public enum ColorMenu {
        public static let columns = 5
        public static let horizontalPadding: CGFloat = 16
        public static let swatchSize: CGFloat = 26
        public static let swatchSpacing: CGFloat = 8
        public static let width: CGFloat = 2 * horizontalPadding + CGFloat(columns) * swatchSize + CGFloat(columns - 1) * swatchSpacing
        /// Над первым разделом; заголовок раздела 32 (надпись с 14 от края, серединой в 15,5 от верха заголовка),
        /// между последним рядом раздела и следующим заголовком 9, под последним рядом 14.
        public static let topPadding: CGFloat = 4
        public static let sectionHeaderHeight: CGFloat = 32
        public static let sectionHeaderTitleX: CGFloat = 14
        public static let sectionHeaderTitleCenterY: CGFloat = 15.5
        public static let sectionSpacing: CGFloat = 9
        public static let bottomPadding: CGFloat = 14
        public static let swatchCornerRadius: CGFloat = 4
        public static let swatchGlyphSize: CGFloat = 15
        public static let swatchBorderWidth: CGFloat = 1
        /// Образец текущего цвета обведён кольцом 2 вместо рамки (у Notion — серое, ≈ 28 % цвета текста).
        public static let currentRingWidth: CGFloat = 2
        public static let currentRingAlpha: CGFloat = 0.3
        /// Рамка образца цвета — тот же оттенок, что у цвета текста, но слабее.
        public static let swatchToneBorderAlpha: CGFloat = 0.4
    }
}
