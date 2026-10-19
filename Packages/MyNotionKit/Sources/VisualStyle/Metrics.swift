import CoreGraphics

/// Размеры и отступы по contracts/visual-style.md, в точках (1 CSS px Notion = 1 pt).
/// Других мест с размерами в коде нет.
public enum Metrics {
    public enum Page {
        public static let columnWidth: CGFloat = 720
        public static let topBarHeight: CGFloat = 44
        /// Поле пути слева в верхней полосе (≈ по снимку).
        public static let topBarHorizontalPadding: CGFloat = 12
        /// Добавки к пробелу перед «/» пути и к самой «/»: просветы от букв ≈ 7,5 до «/» и ≈ 8,5 после, как у Notion (≈ по снимку).
        public static let breadcrumbSpaceBeforeSeparatorKern: CGFloat = 3.25
        public static let breadcrumbSeparatorKern: CGFloat = 4
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
        /// От верхней полосы до названия, когда иконки нет (≈ по снимку Notion: верх букв названия на 65 от верха окна).
        public static let headerTopPaddingWithoutIcon: CGFloat = 32
        /// Эмодзи иконки внутри квадрата `iconSize`: рисунок ≈ 61×74, как у Notion на снимке (≈ по снимку).
        public static let iconFontSize: CGFloat = 78
        /// Под иконкой — место под строку скрытых кнопок, как у Notion (≈ по снимку: верх букв названия на 267).
        public static let iconToTitleSpacing: CGFloat = 40
        /// «Без названия» правее курсора: курсор не налезает на первую букву (≈ по снимку).
        /// Подсказка пустого блока и «Начните вводить для поиска» за «/» — без зазора, с места курсора.
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
        case .heading1: BlockSpacing(height: 90, topSpacing: 38)
        case .heading2: BlockSpacing(height: 76.4, topSpacing: 33)
        case .heading3: BlockSpacing(height: 67, topSpacing: 30)
        }
    }

    /// Выделение через несколько блоков как в Notion (по снимку Юрия 15.10.2026): подложка на блок целиком —
    /// от края блока до края колонки с запасом `horizontalOutset` (текст абзаца на 6 от края подложки),
    /// на `verticalOutset` выше первой и ниже последней строки, со скруглением `cornerRadius`.
    public enum BlockSelection {
        public static let horizontalOutset: CGFloat = 4
        public static let verticalOutset: CGFloat = 3
        public static let cornerRadius: CGFloat = 2.5
        /// Просвет между подложками соседних блоков (Notion 7.38.1 в виртуальном Mac, 15.10.2026: ≈ 3).
        public static let blockGap: CGFloat = 3
    }

    /// Курсор текста как в Notion (по снимку Юрия 15.10.2026): узкая черта на высоту букв шрифта строки
    /// (от верха до низа шрифта, `ascender − descender`), а не на всю строку.
    public enum Caret {
        public static let width: CGFloat = 1
        /// Курсор горит и гаснет с этим шагом, после набора и перемещения загорается сразу.
        public static let blinkInterval: Double = 0.5
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
        /// Линия места сброса при перетаскивании блока (по снимку Notion).
        public static let dropIndicatorHeight: CGFloat = 4
        /// Непрозрачность копии блока, которая едет за мышью (по снимку Notion: текст 111 из 240 на фоне 25).
        public static let dragGhostOpacity: CGFloat = 0.4
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
        public static let syncStatusRowHeight: CGFloat = 30
        /// Нижние строки панели («Корзина»): воздух над разделителем и под ним, отступ от нижнего края окна.
        public static let footerDividerSpacing: CGFloat = 6
        public static let footerBottomInset: CGFloat = 10
    }

    /// Верхняя строка окна — в линию со светофором: шторка панели и «✎» (по снимку Notion для Mac).
    public enum Window {
        /// Середина красной кнопки окна от левого верхнего угла окна, как у Notion (у системы — 15,75; 15,75).
        public static let trafficLightsCenter = CGPoint(x: 20.75, y: 17.75)
        /// Высота строки светофора, шторки и «✎»; середина — на 18 от верха окна, как у Notion.
        public static let titleBarHeight: CGFloat = 36
        /// Кнопки строки: квадрат, значок внутри, скругление фона при наведении.
        public static let toolbarButtonSize: CGFloat = 28
        /// Значки по снимку Notion: шторка ≈ 16,5 × 13,5, «✎» ≈ 13,5 × 13,5.
        public static let sidebarToggleSymbolSize: CGFloat = 15
        public static let newPageSymbolSize: CGFloat = 13
        public static let toolbarButtonCornerRadius: CGFloat = 6
        /// Середина шторки от левого края окна: на 28 правее середины зелёной кнопки, как у Notion.
        public static let sidebarToggleCenterX: CGFloat = 95
        /// Сворачивание и разворот панели.
        public static let sidebarToggleDuration: Double = 0.2
    }

    /// Поле поиска вверху боковой панели (FR-018), как «Search» у Notion 7.38.1 (снимок 17.10.2026, ≈ ±1,5):
    /// рамка на фоне панели, на 10 от краёв окна и панели, под строкой светофора. У Notion лупы нет — у нас есть.
    public enum SearchField {
        public static let height: CGFloat = 30
        public static let cornerRadius: CGFloat = 6
        public static let borderWidth: CGFloat = 1
        /// Добавка к `Sidebar.panelInset` по бокам: поле с 10 от края панели.
        public static let extraHorizontalInset: CGFloat = 2
        /// Воздух над полем (под строкой светофора) и под ним (до «Страницы»).
        public static let topSpacing: CGFloat = 6
        public static let bottomSpacing: CGFloat = 6
        /// Лупа серединой в 14 от левого края поля, текст и подсказка «Поиск» — с 26.
        public static let iconCenterX: CGFloat = 14
        public static let iconSize: CGFloat = 12
        public static let textX: CGFloat = 26
        public static let textTrailingPadding: CGFloat = 8
    }

    /// Выдача поиска: всплывающая карточка под полем поиска, строки как у Notion 7.38.1 (снимок 17.10.2026, ≈ ±1,5):
    /// иконка, название 14, путь родителей 12 серым, кусок текста 12 с найденным словом синим.
    public enum SearchResults {
        public static let width: CGFloat = 420
        public static let maxHeight: CGFloat = 480
        /// Между полем и карточкой.
        public static let anchorSpacing: CGFloat = 4
        /// Поля карточки сверху и снизу; строки отступают от краёв карточки на `PopupMenu.rowInset`.
        public static let verticalPadding: CGFloat = 6
        /// Строка: поля 8 сверху и снизу, название — строка 20, путь и кусок текста — по 18.
        public static let rowVerticalPadding: CGFloat = 8
        public static let titleLineHeight: CGFloat = 20
        public static let detailLineHeight: CGFloat = 18
        /// Иконка — место 20 в 8 от края строки, текст — с 36 от края строки.
        public static let iconSize: CGFloat = 20
        public static let iconFontSize: CGFloat = 15
        public static let textX: CGFloat = 36
        public static let rowTrailingPadding: CGFloat = 10
        /// Заголовок «Найдено: N» над строками, как «Search results (3)» у Notion: 12 medium textSecondary
        /// с края иконок строк, строка 27, как заголовок раздела меню «/».
        public static let headerHeight: CGFloat = 27
        /// Пусто: «Ничего не найдено» (14 medium textPrimary, строка 20) и пояснение под ним (12 textSecondary, строка 18)
        /// по центру карточки, как «No results» у Notion.
        public static let emptyStateHeight: CGFloat = 70
        /// Над буквами строки названия пусто больше, чем под строкой пояснения: обе строки выше на столько,
        /// чтобы по центру стоял сам текст, а не строки.
        public static let emptyStateOpticalLift: CGFloat = 2.5
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

    /// Меню «/», меню блока, выдача поиска: плотный список как в Notion 7.38.1 (снимок 15.10.2026, точность ±1,2).
    public enum PopupMenu {
        public static let cornerRadius: CGFloat = 10
        public static let slashMenuWidth: CGFloat = 324
        public static let blockMenuWidth: CGFloat = 240
        /// Шаг строк; подсветка выбранной строки — на 1 меньше сверху и снизу, скругление 6.
        public static let rowHeight: CGFloat = 33
        public static let rowHighlightInset: CGFloat = 1
        public static let rowCornerRadius: CGFloat = 6
        /// Поля меню сверху; строка отступает 4 от краёв меню; значок и быстрые символы — в 8 от краёв строки.
        public static let verticalPadding: CGFloat = 6
        public static let rowInset: CGFloat = 4
        public static let rowHorizontalPadding: CGFloat = 8
        /// Место значка 20 без рамки; рисунок вписан в квадрат 16 по центру; между значком и названием 8.
        public static let iconSize: CGFloat = 20
        public static let iconInkSize: CGFloat = 16
        public static let iconToTitleSpacing: CGFloat = 8
        /// Размер шрифта надписей «T», «H₁»… и системных значков до вписывания в квадрат.
        public static let iconGlyphSize: CGFloat = 16
        /// Заголовок раздела «Основные блоки» над строками меню «/».
        public static let sectionHeaderHeight: CGFloat = 27
        /// Под строкой «Закрыть меню» до низа меню.
        public static let bottomPadding: CGFloat = 2
        /// Сколько строк видно без прокрутки.
        public static let maximumVisibleRows = 8
        /// Зазор между строкой текста и меню.
        public static let anchorSpacing: CGFloat = 4
        /// Подложка под «/» с поиском в строке, пока открыто меню «/»: скругление и поля по бокам (≈ по Notion).
        public static let slashQueryCornerRadius: CGFloat = 4
        public static let slashQueryHorizontalPadding: CGFloat = 2
        /// Галочка текущего типа в списке типов панели форматирования.
        public static let checkmarkGlyphSize: CGFloat = 12
    }

    /// Окно выбора иконки-эмодзи (FR-034), как у Notion 7.38.1 (снимки 16.10.2026, ±1,2). Отсчёт — от левого верхнего
    /// угла карточки. У Notion справа от «Случайной» выбор оттенка кожи; у нас его нет — поле поиска длиннее.
    public enum EmojiPicker {
        public static let width: CGFloat = 408
        public static let height: CGFloat = 390
        /// Карточка под иконкой (по середине иконки), между ними 4.
        public static let anchorSpacing: CGFloat = 4
        /// Шапка: вкладка «Эмодзи» с 17 от края и чертой 2 под ней (шире текста на 6 с боков), «Убрать» в 17 от правого края.
        public static let headerHeight: CGFloat = 40
        public static let tabTitleX: CGFloat = 17
        public static let tabUnderlineHeight: CGFloat = 2
        public static let tabUnderlineOutset: CGFloat = 6
        public static let removeRightPadding: CGFloat = 17
        /// Поле поиска: с 48 от верха, высота 28, с 10 от края; лупа 14 серединой в 12 от края поля, текст с 28.
        public static let searchTop: CGFloat = 48
        public static let searchHeight: CGFloat = 28
        public static let searchLeft: CGFloat = 10
        public static let searchCornerRadius: CGFloat = 6
        public static let searchIconCenterX: CGFloat = 12
        public static let searchIconSize: CGFloat = 14
        public static let searchTextX: CGFloat = 26
        /// «Случайная» — квадрат 28 со скруглением 6 в 8 от правого края, между полем и ней 8.
        public static let buttonSize: CGFloat = 28
        public static let buttonCornerRadius: CGFloat = 6
        public static let buttonIconSize: CGFloat = 13
        public static let rightPadding: CGFloat = 8
        public static let searchToButtonSpacing: CGFloat = 8
        /// Прокрутка с эмодзи — с 85 от верха до черты над строкой разделов.
        public static let contentTop: CGFloat = 85
        /// Заголовок раздела: строка 39, середина надписи в 25 от её верха, надпись с 10 от края карточки.
        public static let sectionHeaderHeight: CGFloat = 39
        public static let sectionTitleCenterY: CGFloat = 25
        public static let sectionTitleX: CGFloat = 10
        /// Сетка: 12 столбцов по 32 с полями 12; под мышью и выбранная — подложка со скруглением 6.
        public static let columns = 12
        public static let cellSize: CGFloat = 32
        public static let gridPadding: CGFloat = 12
        public static let cellCornerRadius: CGFloat = 6
        public static let emojiFontSize: CGFloat = 22
        /// Результаты поиска — сразу под полем, с 4 от верха прокрутки; «Ничего не найдено» — как заголовок раздела.
        public static let searchResultsTopPadding: CGFloat = 4
        /// Строка разделов внизу: 51 под чертой; значки 17 с шагом 35, первый серединой в 28 от края, середина в 24 под чертой;
        /// текущий раздел — подложка 32 × 32 со скруглением 6.
        public static let sectionBarHeight: CGFloat = 51
        public static let sectionIconPitch: CGFloat = 35
        public static let firstSectionIconCenterX: CGFloat = 28
        public static let sectionIconCenterY: CGFloat = 24
        public static let sectionIconSize: CGFloat = 17
        public static let sectionHighlightSize: CGFloat = 32
    }

    /// Шапка страницы: кнопка «Добавить иконку» при наведении, как у Notion (серая, значок и надпись 14), над названием.
    public enum PageHeaderButton {
        public static let height: CGFloat = 28
        public static let horizontalPadding: CGFloat = 8
        public static let iconSize: CGFloat = 14
        public static let iconToTitleSpacing: CGFloat = 6
        public static let cornerRadius: CGFloat = 6
        /// Между кнопкой и верхом названия.
        public static let titleSpacing: CGFloat = 4
        /// Подсветка иконки страницы под мышью — скругление.
        public static let iconHoverCornerRadius: CGFloat = 6
    }

    /// Панель форматирования над выделенным текстом (FR-033), карточка как у Notion 7.38.1 (снимок 15.10.2026, ±1,2):
    /// строка типа блока, разделитель, ряд из 7 кнопок по 36 (шесть как у Notion и цвет «A»).
    public enum FormatBar {
        public static let horizontalPadding: CGFloat = 6
        public static let verticalPadding: CGFloat = 6
        public static let buttonWidth: CGFloat = 36
        public static let buttonCount = 7
        public static let width: CGFloat = 2 * horizontalPadding + CGFloat(buttonCount) * buttonWidth
        /// Строка типа: середина значка в 18 от края карточки, название с 42, середина стрелки «›» в 23 от правого края.
        public static let kindRowHeight: CGFloat = 32
        public static let kindIconCenterX: CGFloat = 18
        public static let kindTitleX: CGFloat = 42
        public static let kindChevronCenterFromRight: CGFloat = 23
        public static let kindChevronGlyphSize: CGFloat = 11
        /// Полоса разделителя 6: линия 1 на 2 ниже строки типа (середина в 40,5 от верха карточки), с 16 от краёв.
        public static let dividerBandHeight: CGFloat = 6
        public static let dividerOffset: CGFloat = 2
        public static let dividerInset: CGFloat = 16
        public static let dividerWidth: CGFloat = 1
        public static let buttonRowHeight: CGFloat = 31
        /// Размер шрифта системных значков кнопок: рисунок «B» ≈ 11 высотой, как у Notion.
        public static let buttonGlyphSize: CGFloat = 15
        /// Рамка, в которую вписан рисунок значка: у Notion «</>» ≈ 17,5 × 12,7, ссылка ≈ 15 × 15.
        public static let buttonInkBox = CGSize(width: 18, height: 15)
        /// Подсветка кнопки под мышью.
        public static let buttonHighlightSize = CGSize(width: 32, height: 28)
        public static let buttonCornerRadius: CGFloat = 6
        public static let height: CGFloat = 2 * verticalPadding + kindRowHeight + dividerBandHeight + buttonRowHeight
        /// Список типов — сбоку от карточки (Notion, сверено 18.10.2026: ≈ 8,8 ± 1,3) и заходит на неё до подсветки
        /// последней кнопки: поле карточки 6 + половина зазора между местом кнопки 36 и подсветкой 32.
        public static let kindMenuOverlap: CGFloat = horizontalPadding + (buttonWidth - buttonHighlightSize.width) / 2
        /// Между строкой выделения и карточкой (под строкой, а если внизу нет места — над ней).
        public static let selectionSpacing: CGFloat = 8
        /// Левый край карточки правее указателя мыши (или конца выделения, если указатель не над страницей).
        public static let pointerOffset: CGFloat = 14
    }
}

public struct BlockSpacing: Sendable, Hashable {
    public let height: CGFloat
    public let topSpacing: CGFloat
}
