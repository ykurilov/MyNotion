import CoreGraphics

/// Размеры и отступы по contracts/visual-style.md, в точках (1 CSS px Notion = 1 pt).
/// Других мест с размерами в коде нет.
public enum Metrics {
    public enum Page {
        public static let columnWidth: CGFloat = 720
        public static let topBarHeight: CGFloat = 44
        /// Поля пути в верхней полосе (≈ по снимку).
        public static let topBarHorizontalPadding: CGFloat = 12
        public static let iconSize: CGFloat = 78
        public static let titleToFirstBlockSpacing: CGFloat = 8
        /// От верхней полосы до иконки страницы (≈ по снимку).
        public static let headerTopPadding: CGFloat = 38
        /// От верхней полосы до названия, когда иконки нет (≈ по снимку).
        public static let headerTopPaddingWithoutIcon: CGFloat = 80
        /// Эмодзи иконки внутри квадрата `iconSize`: рисунок ≈ 61×74, как у Notion на снимке (≈ по снимку).
        public static let iconFontSize: CGFloat = 78
        public static let iconToTitleSpacing: CGFloat = 4
        /// Поля по бокам колонки, когда окно уже колонки (≈ по снимку).
        public static let minimumSideInset: CGFloat = 96
        /// Пустое место под последним блоком, чтобы конец страницы не прилипал к краю окна.
        public static let bottomPadding: CGFloat = 180
        /// Внутренний отступ блока по краям текста.
        public static let blockHorizontalPadding: CGFloat = 2
        /// Сдвиг вложенного пункта на уровень.
        public static let indentPerLevel: CGFloat = 32
    }

    /// Высота блока в одну строку вместе с отступами и отступ над ним.
    public static func block(_ style: BlockTextStyle) -> BlockSpacing {
        switch style {
        case .paragraph, .listItem: BlockSpacing(height: 30, topSpacing: 3)
        case .heading1: BlockSpacing(height: 79, topSpacing: 32)
        case .heading2: BlockSpacing(height: 67, topSpacing: 26)
        case .heading3: BlockSpacing(height: 58, topSpacing: 22)
        }
    }

    /// Полоса «Изменения не сохранены» над страницей.
    public enum SaveErrorBanner {
        public static let height: CGFloat = 36
        public static let horizontalPadding: CGFloat = 16
    }

    public enum Checkbox {
        public static let size: CGFloat = 16
        public static let cornerRadius: CGFloat = 3
        public static let borderWidth: CGFloat = 1.5
    }

    /// Колонка слева от текста пункта, чекбокса и подстраницы: маркер, номер, квадрат или значок.
    /// Текст блока начинается за колонкой и промежутком (≈ по снимку).
    public enum BlockMarker {
        public static let columnWidth: CGFloat = 24
        public static let textSpacing: CGFloat = 6
        public static var textInset: CGFloat { columnWidth + textSpacing }
        /// Во сколько раз шрифт маркера крупнее текста. Видимый размер у `•`, `◦` и `▪` один, как в Notion,
        /// а знаки в шрифте разные, поэтому и множители разные (≈ по снимку).
        public static let bulletScale: CGFloat = 2.2
        public static let squareBulletScale: CGFloat = 1.6
        /// `◦` — тонкое кольцо размером с `•`: в шрифте этот знак жирный, поэтому он рисуется линией такой толщины (≈ по снимку).
        public static let hollowBulletLineWidth: CGFloat = 1.2
    }

    public enum PageLinkBlock {
        public static let iconSize: CGFloat = 20
        /// Подчёркивание названия: толщина и отступ под базовой линией (≈ по снимку).
        public static let underlineThickness: CGFloat = 1
        public static let underlineOffset: CGFloat = 3
    }

    public enum InlineCode {
        public static let cornerRadius: CGFloat = 4
        public static let verticalPadding: CGFloat = 2.7
        public static let horizontalPadding: CGFloat = 5.4
    }

    /// Ручки «+» и «⋮⋮» слева от колонки у блока под мышью; смещения — от левого края колонки.
    public enum BlockHandles {
        public static let addButtonSize = CGSize(width: 24, height: 24)
        public static let addButtonLeadingOffset: CGFloat = 52
        public static let dragHandleSize = CGSize(width: 18, height: 24)
        public static let dragHandleLeadingOffset: CGFloat = 28
        public static let cornerRadius: CGFloat = 4
        /// Линия места сброса при перетаскивании блока (≈ по Notion).
        public static let dropIndicatorHeight: CGFloat = 4
        /// Сдвиг мыши, после которого щелчок по «⋮⋮» становится перетаскиванием.
        public static let dragThreshold: CGFloat = 3
    }

    public enum Sidebar {
        public static let defaultWidth: CGFloat = 270
        /// Нижний предел перетаскивания края (в contracts/visual-style.md не задан).
        public static let minimumWidth: CGFloat = 200
        /// Верхний предел перетаскивания края (в contracts/visual-style.md не задан).
        public static let maximumWidth: CGFloat = 480
        /// Полоса у края панели, за которую её тянут.
        public static let resizeHandleWidth: CGFloat = 6
        public static let rowHeight: CGFloat = 30
        public static let rowVerticalPadding: CGFloat = 5
        public static let rowHorizontalPadding: CGFloat = 8
        public static let rowCornerRadius: CGFloat = 6
        /// Отступ строк от краёв панели.
        public static let panelInset: CGFloat = 8
        public static let rowIconSize: CGFloat = 20
        /// Эмодзи иконки внутри квадрата `rowIconSize` (≈ по Notion).
        public static let rowEmojiFontSize: CGFloat = 15
        /// Промежуток между иконкой и названием (≈ по Notion).
        public static let rowIconSpacing: CGFloat = 6
        /// Стрелка раскрытия внутри квадрата иконки.
        public static let disclosureSymbolSize: CGFloat = 11
        public static let indentPerLevel: CGFloat = 9
        /// «⋯» и «+» справа в строке при наведении.
        public static let rowAccessorySize: CGFloat = 20
        /// Промежуток между «⋯» и «+»; их фон при наведении — со скруглением `rowAccessoryCornerRadius`.
        public static let rowAccessorySpacing: CGFloat = 2
        public static let rowAccessoryCornerRadius: CGFloat = 4
        public static let searchFieldHeight: CGFloat = 32
        public static let searchFieldCornerRadius: CGFloat = 6
        public static let syncStatusRowHeight: CGFloat = 30
        /// Нижние строки панели («Корзина»): воздух над разделителем и под ним, отступ от нижнего края окна.
        public static let footerDividerSpacing: CGFloat = 6
        public static let footerBottomInset: CGFloat = 10
        /// Окно корзины над строкой «Корзина» (в contracts/visual-style.md не задано).
        public static let trashPopoverWidth: CGFloat = 360
        public static let trashPopoverMaxHeight: CGFloat = 420
    }

    /// Меню «/», меню блока, выдача поиска.
    public enum PopupMenu {
        public static let cornerRadius: CGFloat = 10
        public static let slashMenuWidth: CGFloat = 324
        public static let slashMenuRowHeight: CGFloat = 46
        public static let slashMenuIconSize: CGFloat = 46
        public static let slashMenuIconCornerRadius: CGFloat = 4
        /// Поля меню: сверху и снизу, строк от краёв меню, текста от значка (≈ по снимку).
        public static let verticalPadding: CGFloat = 6
        public static let rowInset: CGFloat = 4
        public static let rowHorizontalPadding: CGFloat = 6
        public static let rowCornerRadius: CGFloat = 6
        public static let iconToTitleSpacing: CGFloat = 10
        /// Меню блока: строки без пояснений.
        public static let blockMenuWidth: CGFloat = 240
        public static let blockMenuRowHeight: CGFloat = 28
        public static let blockMenuIconSize: CGFloat = 20
        /// Шрифт надписи в значке («Aa», «H1»): в меню «/» и в меню блока. Системные значки и квадрат чекбокса —
        /// в `iconSymbolToCapHeight` раза выше заглавных этого шрифта, чтобы все значки были одной высоты (≈ по снимку).
        public static let slashMenuIconGlyphSize: CGFloat = 18
        public static let blockMenuIconGlyphSize: CGFloat = 14
        public static let iconSymbolToCapHeight: CGFloat = 1.2
        /// Сколько строк видно без прокрутки.
        public static let maximumVisibleRows = 8
        /// Зазор между строкой текста и меню.
        public static let anchorSpacing: CGFloat = 4
        /// Подложка под «/» с поиском в строке, пока открыто меню «/»: скругление и поля по бокам (≈ по Notion).
        public static let slashQueryCornerRadius: CGFloat = 4
        public static let slashQueryHorizontalPadding: CGFloat = 2
    }
}

public struct BlockSpacing: Sendable, Hashable {
    public let height: CGFloat
    public let topSpacing: CGFloat
}
