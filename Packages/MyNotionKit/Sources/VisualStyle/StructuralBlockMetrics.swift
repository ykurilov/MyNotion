import AppKit

/// Размеры переключателя, цитаты, выноски и разделителя (contracts/blocks-and-keys.md; FR-119 — сверка с живым Notion
/// в галерее `--only structural`).
extension Metrics {
    /// Треугольник ▸/▾ в колонке маркера: заливка цвета текста (Notion — значок 0,625 em).
    public enum Toggle {
        public static let triangleWidth: CGFloat = 8
        public static let triangleHeight: CGFloat = 9
    }

    /// Черта слева во всю высоту цитаты и её детей, текст правее черты.
    public enum Quote {
        public static let barWidth: CGFloat = 3
        public static let textSpacing: CGFloat = 14
        public static var textInset: CGFloat { barWidth + textSpacing }
    }

    /// Подложка от первой строки до последнего ребёнка, иконка-эмодзи слева от текста (Notion: поля 16 16 16 12,
    /// иконка в квадрате 24, текст на 8 правее).
    public enum Callout {
        public static let verticalPadding: CGFloat = 16
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
