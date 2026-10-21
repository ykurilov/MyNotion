import CoreGraphics

extension Metrics {
    /// Сетка таблицы базы (contracts/database-ui.md, «Таблица»): Notion 7.39, снимки 21.10.2026, 1 px ≈ 1,26 pt.
    /// Цифры с «≈» уточняет US1 по живому Notion (FR-337).
    public enum DatabaseGrid {
        /// Высота строки ≈ 33 (`notion-cell-selected.png`) и строки шапки колонок.
        public static let rowHeight: CGFloat = 33
        public static let headerHeight: CGFloat = 33
        /// Ширина колонки: «Название» ≈ 280, остальные ≈ 200, наименьшая ≈ 100.
        public static let titleColumnWidth: CGFloat = 280
        public static let columnWidth: CGFloat = 200
        public static let minimumColumnWidth: CGFloat = 100
        /// Поля текста в ячейке (как у простой таблицы 002).
        public static let cellHorizontalPadding: CGFloat = 8
        public static let fontSize: CGFloat = 14
        public static let headerFontSize: CGFloat = 14
        /// Плашка варианта: высота 20, скругление 3, поля 6, просвет между плашками 6.
        public static let chipHeight: CGFloat = 20
        public static let chipCornerRadius: CGFloat = 3
        public static let chipHorizontalPadding: CGFloat = 6
        public static let chipSpacing: CGFloat = 6
        public static let chipFontSize: CGFloat = 14
        /// Флажок в ячейке — 16 со скруглением 3.
        public static let checkboxSize: CGFloat = 16
        public static let checkboxCornerRadius: CGFloat = 3
        public static let lineWidth: CGFloat = 1
        /// Строк сверх экрана, которые сетка держит готовыми сверху и снизу.
        public static let overscanRows = 10
    }
}
