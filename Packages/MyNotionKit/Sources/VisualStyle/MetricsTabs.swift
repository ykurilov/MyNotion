import CoreGraphics

extension Metrics {
    /// Полоса вкладок в строке светофора (contracts/pages-ui.md, «Верхняя полоса окна»): замер живого Notion 7.39
    /// для Mac, 20.10.2026, снимок @2x. Высота с линией снизу — `Window.titleBarHeight`.
    public enum Tabs {
        /// Полоса без линии снизу; линия — 1.
        public static let stripHeight: CGFloat = 35
        public static let separatorWidth: CGFloat = 1
        /// Место «‹ ›» от края панели до первой вкладки; середины стрелок — на 19 и 48,5 от его левого края.
        public static let navigationWidth: CGFloat = 68
        public static let backCenterX: CGFloat = 19
        public static let forwardCenterX: CGFloat = 48.5
        /// Стрелки ≈ 6 × 11,5, «+» ≈ 12,5 × 12,5.
        public static let arrowSymbolSize: CGFloat = 12
        public static let plusSymbolSize: CGFloat = 14
        /// При спрятанной панели полоса начинается сразу за шторкой.
        public static let collapsedSidebarLeading: CGFloat = Window.sidebarToggleCenterX + Window.toolbarButtonSize / 2 + 2
        /// Вкладка: 199 и линия справа; когда не влезают — сжимаются поровну до `minimumTabWidth`.
        public static let tabWidth: CGFloat = 199
        public static let minimumTabWidth: CGFloat = 40
        /// Иконка ≈ 15 с 16 от левого края, название — с 16 без иконки и с 39 с иконкой; шрифт 14.
        public static let contentInset: CGFloat = 16
        public static let iconSize: CGFloat = 15
        public static let iconTitleGap: CGFloat = 8
        public static let titleFontSize: CGFloat = 14
        /// «×» ≈ 9,5 × 9,5, серединой в 17 от правого края вкладки; кнопка вокруг — 20.
        public static let closeCenterFromTrailing: CGFloat = 17
        public static let closeSymbolSize: CGFloat = 10
        public static let closeButtonSize: CGFloat = 20
        /// Затухание обрезанного названия неактивной вкладки; у активной — «…».
        public static let titleFadeWidth: CGFloat = 24
        /// «+»: серединой в 20 от правого края последней вкладки.
        public static let plusCenterFromTabsEnd: CGFloat = 20
    }
}
