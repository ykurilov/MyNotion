import CoreGraphics

extension Metrics {
    /// Страница строки базы и её просмотр (contracts/database-ui.md, «Страница строки»): Notion 7.39,
    /// `notion-row-full-page-top.png`, `notion-new-row-side-peek-filtered.png`. Цифры с «≈» уточняет T044 по живому Notion.
    public enum RowPage {
        /// Строка свойства ≈ 34 (шаг строк на снимке ≈ 30 px).
        public static let lineHeight: CGFloat = 34
        /// Колонка «значок и имя» ≈ 160; значение — справа от неё.
        public static let nameColumnWidth: CGFloat = 160
        public static let iconSize: CGFloat = 16
        public static let iconToNameSpacing: CGFloat = 6
        public static let fontSize: CGFloat = 14
        /// Подложка под мышью выступает за текст на это поле и скругляется.
        public static let hoverPadding: CGFloat = 6
        public static let hoverCornerRadius: CGFloat = 4
        /// Над первой строкой и под «+ Добавить свойство» — до тела страницы.
        public static let topPadding: CGFloat = 6
        public static let bottomPadding: CGFloat = 10

        /// Просмотр сбоку: панель справа на высоту окна ≈ 45 % ширины, но не уже `sidePeekMinWidth`.
        public static let sidePeekWidthFraction: CGFloat = 0.45
        public static let sidePeekMinWidth: CGFloat = 420
        /// Просмотр по центру: карточка ≈ 775×610 поверх затемнения (не больше окна без полей `centerPeekMargin`).
        public static let centerPeekWidth: CGFloat = 775
        public static let centerPeekHeight: CGFloat = 610
        public static let centerPeekMargin: CGFloat = 40
        public static let centerPeekCornerRadius: CGFloat = 10
        /// Полоса кнопок «»» и «⤢» вверху просмотра.
        public static let peekBarHeight: CGFloat = 44
        public static let peekButtonSize: CGFloat = 26
        public static let peekButtonSpacing: CGFloat = 2
        public static let peekBarLeading: CGFloat = 12
        public static let peekAnimationDuration: Double = 0.18
    }
}
