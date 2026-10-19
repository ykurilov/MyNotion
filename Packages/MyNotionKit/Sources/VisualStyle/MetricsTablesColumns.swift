import CoreGraphics

extension Metrics {
    /// Колонки (contracts/blocks-and-keys.md, «Колонки»): поток каждой колонки — свой редактор.
    public enum Columns {
        /// Просвет между колонками, как у Notion (≈ по снимку): посередине — граница, которую тянут.
        public static let gap: CGFloat = 46
        /// Полоса границы колонок при наведении.
        public static let dividerWidth: CGFloat = 4
        /// Ширина зоны у правого края блока, где «⋮⋮» ставит блок колонкой справа.
        public static let rightEdgeDropZone: CGFloat = 64
        /// Полоса места сброса у правого края блока.
        public static let dropBarWidth: CGFloat = 4
    }

    /// Простая таблица (contracts/blocks-and-keys.md, «Таблица»): ячейки рисует вид таблицы, правит одно поле.
    public enum Table {
        /// Поля текста в ячейке, как у Notion (≈ по снимку: 7 сверху и снизу, 9 по бокам).
        public static let cellVerticalPadding: CGFloat = 7
        public static let cellHorizontalPadding: CGFloat = 9
        /// Шрифт ячейки и высота строки текста.
        public static let fontSize: CGFloat = 14
        public static let lineHeight: CGFloat = 20
        /// Наименьшая высота строки таблицы.
        public static let minimumRowHeight: CGFloat = 34
        public static let borderWidth: CGFloat = 1
        /// Кнопки «+» под таблицей и справа от неё.
        public static let addButtonThickness: CGFloat = 18
        public static let addButtonGap: CGFloat = 4
        /// Зона у границы столбца, за которую тянут ширину.
        public static let resizeHandleWidth: CGFloat = 6
        /// Отступы над и под таблицей.
        public static let verticalMargin: CGFloat = 6
    }
}
