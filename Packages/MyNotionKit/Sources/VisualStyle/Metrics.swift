import CoreGraphics

/// Размеры и отступы по contracts/visual-style.md, в точках (1 CSS px Notion = 1 pt).
/// Других мест с размерами в коде нет.
public enum Metrics {
    public enum Page {
        public static let columnWidth: CGFloat = 720
        public static let topBarHeight: CGFloat = 44
        public static let iconSize: CGFloat = 78
        public static let titleToFirstBlockSpacing: CGFloat = 8
        /// Внутренний отступ блока по краям текста.
        public static let blockHorizontalPadding: CGFloat = 2
        /// Сдвиг вложенного пункта на уровень.
        public static let indentPerLevel: CGFloat = 36
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

    public enum Checkbox {
        public static let size: CGFloat = 16
        public static let cornerRadius: CGFloat = 3
        public static let borderWidth: CGFloat = 1.5
    }

    public enum PageLinkBlock {
        public static let iconSize: CGFloat = 20
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
    }

    public enum Sidebar {
        public static let defaultWidth: CGFloat = 270
        /// Нижний предел перетаскивания края (в contracts/visual-style.md не задан).
        public static let minimumWidth: CGFloat = 200
        public static let rowHeight: CGFloat = 30
        public static let rowVerticalPadding: CGFloat = 5
        public static let rowHorizontalPadding: CGFloat = 8
        public static let rowCornerRadius: CGFloat = 6
        /// Отступ строк от краёв панели.
        public static let panelInset: CGFloat = 8
        public static let rowIconSize: CGFloat = 20
        public static let indentPerLevel: CGFloat = 9
        /// «⋯» и «+» справа в строке при наведении.
        public static let rowAccessorySize: CGFloat = 20
        public static let searchFieldHeight: CGFloat = 32
        public static let searchFieldCornerRadius: CGFloat = 6
        public static let syncStatusRowHeight: CGFloat = 30
    }

    /// Меню «/», меню блока, выдача поиска.
    public enum PopupMenu {
        public static let cornerRadius: CGFloat = 10
        public static let slashMenuWidth: CGFloat = 324
        public static let slashMenuRowHeight: CGFloat = 46
        public static let slashMenuIconSize: CGFloat = 46
    }
}

public struct BlockSpacing: Sendable, Hashable {
    public let height: CGFloat
    public let topSpacing: CGFloat
}
