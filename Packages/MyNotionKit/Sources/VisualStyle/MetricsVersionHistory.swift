import CoreGraphics

extension Metrics {
    /// «История версий» на всё окно, как у Notion 7.39 (замер дерева страницы 21.10.2026, панель Notion 320 при боковой 270).
    public enum VersionHistory {
        /// Левая панель: шире боковой (у Notion 320 против 270) — кнопки строки светофора над ней стоят внутри.
        public static let panelWidth: CGFloat = 320
        /// Подпись «История версий», название и «Группировать» — в 24 от края; список — в 12, строка версии — 64, текст в 12 от её края.
        public static let headerInset: CGFloat = 24
        public static let headerTop: CGFloat = 12
        public static let listInset: CGFloat = 12
        public static let rowHeight: CGFloat = 64
        public static let rowPadding: CGFloat = 12
        /// «Группировать: 1 мин ▾»: высота 20, поля 6, скругление 4; под ним до списка 12.
        public static let groupingHeight: CGFloat = 20
        public static let groupingPadding: CGFloat = 6
        public static let groupingChevronSize: CGFloat = 8
        /// Список группировки: ширина 180 от левого края кнопки, на 6 ниже неё; заголовок «Группировать изменения» и строки 28.
        public static let groupingMenuWidth: CGFloat = 180
        public static let groupingMenuGap: CGFloat = 6
        /// Справа — строка времени высотой 64 с «Восстановить» (28) и «×».
        public static let previewHeaderHeight: CGFloat = 64
        public static let previewHeaderInset: CGFloat = 16
        /// Раскрытая версия: аватар 16 автора, от карточки версии к нему — линия.
        public static let avatarSize: CGFloat = 16
        public static let threadLineWidth: CGFloat = 1
    }
}
