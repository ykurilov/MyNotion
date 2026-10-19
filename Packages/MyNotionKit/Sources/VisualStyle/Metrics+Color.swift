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
    public enum ColorMenu {
        public static let width: CGFloat = PopupMenu.blockMenuWidth
        /// Выше окно не растёт — дальше прокрутка.
        public static let maximumHeight: CGFloat = 400
        /// Образец цвета слева в строке: квадрат со скруглением, в нём «A».
        public static let swatchSize: CGFloat = PopupMenu.iconSize
        public static let swatchCornerRadius: CGFloat = 4
        public static let swatchGlyphSize: CGFloat = 13
        public static let swatchBorderWidth: CGFloat = 1
        /// Образец текущего цвета обведён кольцом (у Notion — толстая рамка основным цветом текста).
        public static let currentRingWidth: CGFloat = 2
        /// Рамка образца цвета — тот же оттенок, что у цвета текста, но слабее.
        public static let swatchToneBorderAlpha: CGFloat = 0.55
        /// Подчёркивание кнопки «A» на панели последним цветом.
        public static let barUnderlineSize = CGSize(width: 14, height: 2)
        public static let barUnderlineSpacing: CGFloat = 2
    }
}
