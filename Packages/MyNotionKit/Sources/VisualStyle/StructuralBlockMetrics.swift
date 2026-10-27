import CoreGraphics

/// Размеры переключателя, цитаты, выноски и разделителя (contracts/blocks-and-keys.md; FR-119 — сверка с живым Notion
/// в галерее `--only structural`).
extension Metrics {
    /// Треугольник ▸/▾ в колонке маркера: заливка цвета текста (Notion — значок 0,625 em).
    public enum Toggle {
        public static let triangleWidth: CGFloat = 8
        public static let triangleHeight: CGFloat = 9
        /// От строки раскрытого переключателя до текста первого ребёнка у Notion 7.39 — 34 при обычном шаге строк 30.
        public static let childrenTopSpacing: CGFloat = 4
    }

    /// Свёрнутый заголовок: стрелка — та же, что у переключателя (`Toggle`), в месте «+» ручек; справа от текста —
    /// серая подпись «…N блоков» шрифтом абзаца.
    public enum HeadingFold {
        /// От конца текста заголовка до подписи.
        public static let labelSpacing: CGFloat = 8
    }

    /// Черта слева во всю высоту цитаты и её детей, текст правее черты.
    public enum Quote {
        public static let barWidth: CGFloat = 3
        public static let textSpacing: CGFloat = 14
        public static var textInset: CGFloat { barWidth + textSpacing }
    }

    /// Подложка от первой строки до последнего ребёнка, иконка-эмодзи слева от текста (Notion: поля 16 16 16 12,
    /// иконка в квадрате 24, текст на 8 правее). Сверху и снизу — от строки текста: выноска в одну строку у Notion 7.39
    /// 65,5 ± 1,3 (снимок 19.10.2026, «MyNotion — блоки 002»), у нас 24 + 2 × 21 = 66.
    public enum Callout {
        public static let verticalPadding: CGFloat = 21
        public static let leadingPadding: CGFloat = 12
        public static let iconColumnWidth: CGFloat = 24
        public static let iconFontSize: CGFloat = 20
        public static let iconTextSpacing: CGFloat = 8
        public static let cornerRadius: CGFloat = 4
        public static var textInset: CGFloat { leadingPadding + iconColumnWidth + iconTextSpacing }
        /// Отступ над выноской и под ней, как у абзаца.
        public static let outerSpacing: CGFloat = 4
    }

    /// Строка разделителя и линия по её середине.
    public enum Divider {
        public static let rowHeight: CGFloat = 13
        public static let lineWidth: CGFloat = 1
        public static let verticalSpacing: CGFloat = 1
    }
}
