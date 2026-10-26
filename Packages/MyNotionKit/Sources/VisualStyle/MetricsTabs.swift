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
        public static func collapsedSidebarLeading(isFullScreen: Bool) -> CGFloat {
            Window.sidebarToggleCenterX(isFullScreen: isFullScreen) + Window.toolbarButtonSize / 2 + 2
        }
        /// Вкладка: 199 и линия справа; когда не влезают — сжимаются поровну до `minimumTabWidth`.
        public static let tabWidth: CGFloat = 199
        public static let minimumTabWidth: CGFloat = 40
        /// Иконка ≈ 15 с 16 от левого края, название — с 16 без иконки и с 39 с иконкой; шрифт 13 (замер 21.10.2026).
        public static let contentInset: CGFloat = 16
        public static let iconSize: CGFloat = 15
        public static let iconTitleGap: CGFloat = 8
        public static let titleFontSize: CGFloat = 13
        /// «×» ≈ 9,5 × 9,5, серединой в 17 от правого края вкладки; кнопка вокруг — 20.
        public static let closeCenterFromTrailing: CGFloat = 17
        public static let closeSymbolSize: CGFloat = 10
        public static let closeButtonSize: CGFloat = 20
        /// Затухание обрезанного названия неактивной вкладки; у активной — «…».
        public static let titleFadeWidth: CGFloat = 24
        /// «+»: серединой в 20 от правого края последней вкладки.
        public static let plusCenterFromTabsEnd: CGFloat = 20
        /// Самое узкое место под название: уже — названия нет, видна только иконка.
        public static let minimumTitleWidth: CGFloat = 4
    }
}

/// Что помещается во вкладку шириной `width`, как у Notion 7.39 (замер полосы 21.10.2026: 14 и 25 вкладок, ширины 76,6 и 41,2).
/// Поля слева и справа — 16, у узкой вкладки — четверть её ширины. Место под «×» отнимается у названия только под мышью.
/// Название — то, что осталось за иконкой; не осталось — видна одна иконка. У вкладки без иконки название видно всегда,
/// поэтому активная вкладка не бывает пустой.
public struct TabContentLayout: Equatable, Sendable {
    public let inset: CGFloat
    public let titleWidth: CGFloat
    public var showsTitle: Bool { titleWidth > 0 }

    public init(width: CGFloat, hasIcon: Bool, isHovered: Bool) {
        typealias Tabs = Metrics.Tabs
        inset = min(Tabs.contentInset, (width / 4).rounded(.down))
        let closeReserve = isHovered ? Tabs.closeCenterFromTrailing + Tabs.closeButtonSize / 2 + 4 - inset : 0
        let room = width - 2 * inset - closeReserve - (hasIcon ? Tabs.iconSize + Tabs.iconTitleGap : 0)
        titleWidth = room >= Tabs.minimumTitleWidth || !hasIcon ? max(room, 0) : 0
    }
}
