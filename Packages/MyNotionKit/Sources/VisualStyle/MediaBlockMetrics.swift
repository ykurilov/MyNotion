import AppKit

/// Размеры картинки, файла, видео и закладки (contracts/blocks-and-keys.md; FR-119 — сверка с живым Notion
/// в галерее `--only media`).
extension Metrics {
    public enum Media {
        /// Поле над и под картинкой, видео, строкой файла и карточкой закладки.
        public static let verticalPadding: CGFloat = 4
        /// Строка подписи под картинкой и видео: отступ 6 и строка 20.
        public static let captionSpacing: CGFloat = 6
        public static let captionLineHeight: CGFloat = 20
        public static var captionHeight: CGFloat { captionSpacing + captionLineHeight }
        public static let captionFontSize: CGFloat = 14
        /// Скругление картинки, заглушки и видео.
        public static let cornerRadius: CGFloat = 4
        /// Ширина картинки и видео — доля колонки.
        public static let minimumWidthFraction: Double = 0.1
        /// Ручки ширины по бокам картинки под мышью.
        public static let resizeHandleWidth: CGFloat = 6
        public static let resizeHandleHeight: CGFloat = 48
        public static let resizeHandleInset: CGFloat = 8
        /// Кнопка «⋯» в правом верхнем углу под мышью.
        public static let menuButtonSize: CGFloat = 24
        public static let menuButtonInset: CGFloat = 6
        /// Пропорции заглушки, пока размер картинки неизвестен, и видео.
        public static let defaultAspectRatio: CGFloat = 9.0 / 16.0
        /// Кнопка ▶ по центру видео.
        public static let playButtonSize: CGFloat = 56

        /// Строка файла: значок 20, имя 14, размер 12 серым.
        public static let fileRowHeight: CGFloat = 30
        public static let fileIconSize: CGFloat = 20
        public static let fileIconTextSpacing: CGFloat = 6
        public static let fileHorizontalPadding: CGFloat = 4
        public static let fileNameFontSize: CGFloat = 14
        public static let fileSizeFontSize: CGFloat = 12
        public static let fileNameSizeSpacing: CGFloat = 6

        /// Карточка закладки: слева заголовок 14 medium, описание 12 серым в 2 строки, значок 16 и адрес 12;
        /// справа картинка сайта на 33 % ширины; рамка 1, скругление 4.
        public static let bookmarkHeight: CGFloat = 106
        public static let bookmarkPadding: CGFloat = 14
        public static let bookmarkImageFraction: CGFloat = 0.33
        public static let bookmarkTitleFontSize: CGFloat = 14
        public static let bookmarkDescriptionFontSize: CGFloat = 12
        public static let bookmarkURLFontSize: CGFloat = 12
        public static let bookmarkIconSize: CGFloat = 16
        public static let bookmarkLineSpacing: CGFloat = 4
    }
}
