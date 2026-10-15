import CoreGraphics

/// Размеры и отступы по contracts/visual-style.md, в точках (1 CSS px Notion = 1 pt).
/// Других мест с размерами в коде нет.
public enum Metrics {
    public enum Page {
        public static let columnWidth: CGFloat = 720
        public static let topBarHeight: CGFloat = 44
        /// Поле пути слева в верхней полосе (≈ по снимку).
        public static let topBarHorizontalPadding: CGFloat = 12
        /// Запас справа от пути: длинный путь не упирается в край окна.
        public static let topBarTrailingInset: CGFloat = 24
        /// Затухание прокрученного текста под верхней полосой; верхние `scrollEdgeSolidHeight` — сплошной фон страницы.
        public static let scrollEdgeFadeHeight: CGFloat = 16
        public static let scrollEdgeSolidHeight: CGFloat = 4
        public static let iconSize: CGFloat = 78
        /// От названия до первого блока (≈ по снимку Notion: верх букв абзаца на 68 ниже верха букв названия).
        public static let titleToFirstBlockSpacing: CGFloat = 20
        /// От верхней полосы до квадрата иконки (≈ по снимку Notion: середина иконки на 179 от верха окна).
        public static let headerTopPadding: CGFloat = 96
        /// От верхней полосы до названия, когда иконки нет: тот же верхний отступ и место под строку кнопок.
        public static let headerTopPaddingWithoutIcon: CGFloat = 136
        /// Эмодзи иконки внутри квадрата `iconSize`: рисунок ≈ 61×74, как у Notion на снимке (≈ по снимку).
        public static let iconFontSize: CGFloat = 78
        /// Под иконкой — место под строку скрытых кнопок, как у Notion (≈ по снимку: верх букв названия на 267).
        public static let iconToTitleSpacing: CGFloat = 40
        /// Подсказка пустого блока и «Без названия» правее курсора: курсор не налезает на первую букву (≈ по снимку).
        public static let emptyHintCaretGap: CGFloat = 1.5
        /// Поля по бокам колонки, когда окно уже колонки (≈ по снимку).
        public static let minimumSideInset: CGFloat = 96
        /// Пустое место под последним блоком, чтобы конец страницы не прилипал к краю окна.
        public static let bottomPadding: CGFloat = 180
        /// Внутренний отступ блока по краям текста.
        public static let blockHorizontalPadding: CGFloat = 2
        /// Добавка к отступу между абзацем и пунктом списка, чекбоксом или подстраницей, в обе стороны:
        /// шаг строк ≈ 40 вместо 30, как у Notion (≈ по снимку).
        public static let paragraphListSpacing: CGFloat = 10
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
        /// Высота строки и её подсветки.
        public static let rowHeight: CGFloat = 30
        /// Шаг строк дерева: подсветка 30 и зазор 1 между соседними, как у Notion (по снимку).
        public static let rowPitch: CGFloat = 31
        public static let rowVerticalPadding: CGFloat = 5
        public static let rowHorizontalPadding: CGFloat = 8
        public static let rowCornerRadius: CGFloat = 6
        /// Отступ строк от краёв панели.
        public static let panelInset: CGFloat = 8
        /// Квадрат иконки: 16…38 от края панели, как у Notion (по снимку).
        public static let rowIconSize: CGFloat = 22
        /// Эмодзи иконки внутри квадрата `rowIconSize` (≈ по Notion).
        public static let rowEmojiFontSize: CGFloat = 15
        /// Промежуток между иконкой и названием: текст с 46 от края панели (по снимку Notion).
        public static let rowIconSpacing: CGFloat = 8
        /// Стрелка раскрытия внутри квадрата иконки.
        public static let disclosureSymbolSize: CGFloat = 11
        public static let indentPerLevel: CGFloat = 9
        /// «⋯» и «+» справа в строке при наведении.
        public static let rowAccessorySize: CGFloat = 20
        /// Промежуток между «⋯» и «+»; их фон при наведении — со скруглением `rowAccessoryCornerRadius`.
        public static let rowAccessorySpacing: CGFloat = 2
        public static let rowAccessoryCornerRadius: CGFloat = 4
        /// Значки «⋯», «+», «вернуть», «удалить»: один размер (≈ по Notion).
        public static let accessorySymbolSize: CGFloat = 13
        public static let searchFieldHeight: CGFloat = 32
        public static let searchFieldCornerRadius: CGFloat = 6
        public static let syncStatusRowHeight: CGFloat = 30
        /// Нижние строки панели («Корзина»): воздух над разделителем и под ним, отступ от нижнего края окна.
        public static let footerDividerSpacing: CGFloat = 6
        public static let footerBottomInset: CGFloat = 10
    }

    /// Верхняя строка окна — в линию со светофором: шторка панели и «✎» (по снимку Notion для Mac).
    public enum Window {
        /// Высота строки светофора; середина — на 16 от верха окна, как у системных кнопок.
        public static let titleBarHeight: CGFloat = 32
        /// Кнопки строки: квадрат, значок внутри, скругление фона при наведении.
        public static let toolbarButtonSize: CGFloat = 28
        /// Значки по снимку Notion: шторка ≈ 16,5 × 13,5, «✎» ≈ 13,5 × 13,5.
        public static let sidebarToggleSymbolSize: CGFloat = 15
        public static let newPageSymbolSize: CGFloat = 13
        public static let toolbarButtonCornerRadius: CGFloat = 6
        /// Середина шторки от левого края окна: на 28 правее середины зелёной кнопки, как у Notion.
        public static let sidebarToggleCenterX: CGFloat = 90
        /// Сворачивание и разворот панели.
        public static let sidebarToggleDuration: Double = 0.2
    }

    /// Окно корзины: всплывающая панель справа от боковой панели, у строки «Корзина».
    public enum TrashPanel {
        public static let width: CGFloat = 360
        public static let maxHeight: CGFloat = 420
        /// Зазор между боковой панелью и окном корзины.
        public static let sidebarGap: CGFloat = 4
        /// Окно корзины не подходит к краям окна приложения ближе этого.
        public static let windowMargin: CGFloat = 8
        /// Поле карточки вокруг строк (как у строк меню).
        public static let contentInset: CGFloat = 4
        /// Место под тени вокруг карточки в окне панели.
        public static let shadowMargin: CGFloat = 32
    }

    /// Вопрос перед необратимым действием: карточка по центру содержимого окна.
    public enum Confirmation {
        public static let width: CGFloat = 300
        public static let padding: CGFloat = 20
        /// Между заголовком и пояснением.
        public static let textSpacing: CGFloat = 6
        /// Между текстом и кнопками.
        public static let buttonsSpacing: CGFloat = 16
        public static let buttonHeight: CGFloat = 32
        public static let buttonSpacing: CGFloat = 8
        public static let buttonCornerRadius: CGFloat = 6
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
        /// Исходный размер шрифта надписи в значке («Aa», «H1») и системных значков; на экране они подогнаны под `…IconInkSize`.
        public static let slashMenuIconGlyphSize: CGFloat = 18
        public static let blockMenuIconGlyphSize: CGFloat = 14
        /// Квадрат рисунка значка: все значки вписаны в него и стоят по его центру — одна колонка одной ширины,
        /// как в Notion (раунд 2, № 6; ≈ по снимку).
        public static let slashMenuIconInkSize: CGFloat = 24
        public static let blockMenuIconInkSize: CGFloat = 16
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
