import AppKit

/// Цвета светлой и тёмной темы по contracts/visual-style.md. Каждый цвет сам
/// переключается вместе с темой Mac. Других мест с цветами в коде нет.
public enum Palette {
    public static let textPrimary = themed(light: .hex(0x2C2C2B), dark: .hex(0xF0EFED))
    public static let textSecondary = themed(light: .hex(0x7D7A75), dark: .hex(0x9B9A97))
    /// Названия строк панели. Тёмная — по снимку Notion для Mac 15.10.2026; светлая — прежняя, снимка нет.
    public static let sidebarText = themed(light: .hex(0x5F5E59), dark: .hex(0xBCBAB7))
    /// Значок документа и «Корзины» в строках панели: тусклее названия, как у Notion.
    public static let sidebarIcon = themed(light: .hex(0x5F5E59), dark: .hex(0x9B9A97))
    /// Заголовок группы «Страницы» (тёмная — по снимку Notion).
    public static let sidebarGroupHeader = themed(light: .hex(0x7D7A75), dark: .hex(0x7C7A76))
    /// Шторка панели и «✎» в верхней строке окна (тёмная — по снимку Notion).
    public static let windowToolbarIcon = themed(light: .hex(0x7D7A75), dark: .hex(0xACA9A4))
    /// Линия между панелью и страницей (тёмная — по снимку Notion).
    public static let sidebarEdge = themed(light: .hex(0xE6E5E3), dark: .hex(0x2C2C2B))
    public static let pageBackground = themed(light: .hex(0xFFFFFF), dark: .hex(0x191919))
    /// «/» между страницами пути в верхней полосе: тусклый (≈ по снимку Notion 15.10.2026).
    public static let breadcrumbSeparator = themed(light: .rgba(55, 53, 47, 0.15), dark: .rgba(255, 255, 255, 0.1))
    public static let sidebarBackground = themed(light: .hex(0xF9F8F7), dark: .hex(0x202020))
    public static let border = themed(light: .hex(0xE6E5E3), dark: .hex(0x2F2F2F))
    /// Строка дерева под мышью или выбранная, кнопки при наведении.
    public static let hoverBackground = themed(light: .rgba(33, 27, 23, 0.05), dark: .rgba(255, 255, 255, 0.055))
    public static let inlineCodeText = themed(light: .hex(0xCF5148), dark: .hex(0xCF5148))
    public static let inlineCodeBackground = themed(light: .rgba(33, 27, 23, 0.05), dark: .rgba(255, 255, 255, 0.055))
    public static let checkboxChecked = themed(light: .hex(0x2383E2), dark: .hex(0x2383E2))
    /// «+», «⋮⋮», стрелки раскрытия.
    /// Жёлтая полоса ошибки сохранения (желтый фон блока Notion, ≈).
    public static let saveErrorBannerBackground = themed(light: .hex(0xFBF3DB), dark: .hex(0x3F3622))
    public static let handleIcon = themed(light: .rgba(55, 53, 47, 0.35), dark: .rgba(255, 255, 255, 0.3))
    /// Линия места сброса при перетаскивании блока: синий Notion в обеих темах (по снимку Notion).
    public static let dropIndicator = themed(light: .rgba(35, 131, 226, 0.43), dark: .rgba(35, 131, 226, 0.43))
    /// Выделение текста: синий Notion поверх страницы, текст в выделении своего цвета (по снимку Notion 15.10.2026).
    public static let textSelection = themed(light: .rgba(35, 131, 226, 0.28), dark: .rgba(35, 131, 226, 0.28))
    /// Выделение блоков целиком: тот же синий Notion, вдвое прозрачнее (по снимку Notion 15.10.2026).
    public static let blockSelection = themed(light: .rgba(35, 131, 226, 0.14), dark: .rgba(35, 131, 226, 0.14))
    /// Галочка в отмеченном чекбоксе.
    public static let checkboxCheckmark = themed(light: .hex(0xFFFFFF), dark: .hex(0xFFFFFF))
    /// Подчёркивание ссылки: ≈ 40 % цвета текста.
    public static let linkUnderline = themed(
        light: .hex(0x2C2C2B).withAlphaComponent(0.4),
        dark: .hex(0xF0EFED).withAlphaComponent(0.4)
    )

    /// Метка «Две версии» у блока в конфликте (FR-021): оранжевая метка Notion (≈ по Notion: текст #D9730D / #FFA344,
    /// фон #FBECDD / #5C3B23).
    public static let conflictLabelText = themed(light: .hex(0xD9730D), dark: .hex(0xFFA344))
    public static let conflictLabelBackground = themed(light: .hex(0xFBECDD), dark: .hex(0x5C3B23))
    /// Разрушающие действия: «Удалить» в меню блока, «Очистить корзину» под мышью — красный Notion (≈).
    public static let destructiveText = themed(light: .hex(0xD44C47), dark: .hex(0xFF7369))
    /// Кнопка необратимого действия в вопросе («Удалить навсегда»): насыщенный красный под белый текст в обеих темах (≈ по Notion).
    public static let destructiveButtonFill = NSColor.hex(0xD44C47)
    /// Затемнение под вопросом: над содержимым окна и всеми панелями (≈ по Notion).
    /// Главная кнопка окон-вопросов и итогов (синяя, как у Notion), обе темы; текст на ней белый.
    public static let primaryButtonFill = NSColor.hex(0x2383E2)
    public static let modalBackdrop = themed(light: .rgba(15, 15, 15, 0.6), dark: .rgba(0, 0, 0, 0.6))
    /// Фон всплывающих панелей (меню, окно корзины): в тёмной теме светлее страницы, как в Notion (≈ по Notion).
    public static let popupMenuBackground = themed(light: .hex(0xFFFFFF), dark: .hex(0x252525))
    /// Разделитель внутри всплывающей панели (панель форматирования), по снимкам Notion 15.10.2026.
    /// Рамка поля поиска: светлая — как border; тёмная — по снимку Notion 7.38.1 (17.10.2026: ≈ #373735), заметнее border.
    public static let searchFieldBorder = themed(light: .hex(0xE6E5E3), dark: .hex(0x373735))
    /// Найденная часть слова в выдаче поиска (Notion 7.38.1, снимок 17.10.2026: ≈ #2783DE).
    public static let searchHighlight = themed(light: .hex(0x2383E2), dark: .hex(0x2383E2))
    public static let popupDivider = themed(light: .hex(0xF0EFED), dark: .hex(0x373736))
    /// Значок нажатой кнопки панели форматирования — синий, как у Notion (снимок 15.10.2026).
    public static let formatBarActiveIcon = themed(light: .hex(0x2383E2), dark: .hex(0x2383E2))
    /// Окно эмодзи (снимки Notion 16.10.2026): поле поиска, его синяя рамка, значки (лупа, «Случайная», разделы),
    /// неактивный значок «Недавних», надписи разделов, «Убрать», рамка кнопки, черта над строкой разделов.
    public static let emojiSearchBackground = themed(light: .hex(0xF9F8F7), dark: .hex(0x2C2C2C))
    public static let focusRing = themed(light: .hex(0x2383E2), dark: .hex(0x2383E2))
    public static let emojiPickerIcon = themed(light: .hex(0x8E8B86), dark: .hex(0xADA9A3))
    public static let emojiPickerIconDisabled = themed(light: .hex(0xD2D1CF), dark: .hex(0x5B5A57))
    public static let emojiSectionTitle = themed(light: .hex(0x7D7A75), dark: .hex(0xADA9A3))
    public static let emojiPickerAction = themed(light: .hex(0x8E8B86), dark: .hex(0x8E8B86))
    public static let emojiButtonBorder = themed(light: .hex(0xE6E5E3), dark: .hex(0x3B3B39))
    public static let emojiSectionBarDivider = themed(light: .hex(0xF0EFED), dark: .hex(0x2C2C2B))
    /// «Добавить иконку» в шапке страницы: серая надпись и значок (тёмная — по снимку Notion 16.10.2026, светлая ≈).
    public static let pageHeaderButton = themed(light: .hex(0x9B9A97), dark: .hex(0x7D7A75))

    /// Тень всплывающих панелей: четыре слоя, последний — тонкая рамка. В тёмной теме тень гуще, а рамка светлая:
    /// тёмная тень на тёмной странице не видна (≈ по Notion).
    public static let popupMenuShadow: [ShadowLayer] = [
        ShadowLayer(offsetY: 20, blurRadius: 24, spread: 0, color: themed(light: .rgba(25, 25, 25, 0.05), dark: .rgba(0, 0, 0, 0.4))),
        ShadowLayer(offsetY: 5, blurRadius: 8, spread: 0, color: themed(light: .rgba(25, 25, 25, 0.027), dark: .rgba(0, 0, 0, 0.2))),
        // Мягкая тень со всех сторон: верхний край не выглядит срезом строки страницы.
        ShadowLayer(offsetY: 0, blurRadius: 8, spread: 0, color: themed(light: .rgba(15, 15, 15, 0.1), dark: .rgba(0, 0, 0, 0.6))),
        ShadowLayer(offsetY: 0, blurRadius: 0, spread: 1, color: themed(light: .rgba(42, 28, 0, 0.07), dark: .rgba(255, 255, 255, 0.094))),
    ]

    private static func themed(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

/// Цвета Notion: девять оттенков (по умолчанию — отсутствие оттенка). Имена те же, что у `NotionColor` в модели.
public enum NotionTone: String, Sendable, Hashable, CaseIterable {
    case gray, brown, orange, yellow, green, blue, purple, pink, red
}

extension Palette {
    /// Цвет текста Notion; `nil` — основной цвет текста страницы. Предварительные значения — contracts/blocks-and-keys.md,
    /// сверка с живым Notion — этап 7 (FR-119).
    public static func notionText(_ tone: NotionTone?) -> NSColor {
        guard let tone else { return textPrimary }
        return notionTextColors[tone] ?? textPrimary
    }

    /// Цвет подложки Notion (фон текста или блока); `nil` — без подложки.
    public static func notionBackground(_ tone: NotionTone?) -> NSColor? {
        guard let tone else { return nil }
        return notionBackgroundColors[tone]
    }

    private static let notionTextColors: [NotionTone: NSColor] = [
        .gray: themed(light: .hex(0x787774), dark: .hex(0x9B9B9B)),
        .brown: themed(light: .hex(0x9F6B53), dark: .hex(0xBA856F)),
        .orange: themed(light: .hex(0xD9730D), dark: .hex(0xC77D48)),
        .yellow: themed(light: .hex(0xCB912F), dark: .hex(0xCA9849)),
        .green: themed(light: .hex(0x448361), dark: .hex(0x529E72)),
        .blue: themed(light: .hex(0x337EA9), dark: .hex(0x379AD3)),
        .purple: themed(light: .hex(0x9065B0), dark: .hex(0x9D68D3)),
        .pink: themed(light: .hex(0xC14C8A), dark: .hex(0xD15796)),
        .red: themed(light: .hex(0xD44C47), dark: .hex(0xDF5452)),
    ]

    private static let notionBackgroundColors: [NotionTone: NSColor] = [
        .gray: themed(light: .hex(0xF1F1EF), dark: .hex(0x2F2F2F)),
        .brown: themed(light: .hex(0xF4EEEE), dark: .hex(0x4A3228)),
        .orange: themed(light: .hex(0xFBECDD), dark: .hex(0x5C3B23)),
        .yellow: themed(light: .hex(0xFBF3DB), dark: .hex(0x564328)),
        .green: themed(light: .hex(0xEDF3EC), dark: .hex(0x243D30)),
        .blue: themed(light: .hex(0xE7F3F8), dark: .hex(0x143A4E)),
        .purple: themed(light: .hex(0xF6F3F9), dark: .hex(0x3C2D49)),
        .pink: themed(light: .hex(0xFAF1F5), dark: .hex(0x4E2C3C)),
        .red: themed(light: .hex(0xFDEBEC), dark: .hex(0x522E2A)),
    ]
}

/// Один слой тени в духе CSS `box-shadow`.
public struct ShadowLayer: Sendable {
    public let offsetY: CGFloat
    public let blurRadius: CGFloat
    public let spread: CGFloat
    public let color: NSColor
}

extension NSColor {
    fileprivate static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    fileprivate static func rgba(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }
}
