#if canImport(AppKit)
import AppKit

/// Цвета светлой и тёмной темы по contracts/visual-style.md. Каждый цвет сам
/// переключается вместе с темой Mac. Других мест с цветами в коде нет.
public enum Palette {
    public static let textPrimary = themed(PaletteValues.textPrimary)
    public static let textSecondary = themed(PaletteValues.textSecondary)
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
    public static let pageBackground = themed(PaletteValues.pageBackground)
    /// «/» между страницами пути в верхней полосе: тусклый (≈ по снимку Notion 15.10.2026).
    public static let breadcrumbSeparator = themed(light: .rgba(55, 53, 47, 0.15), dark: .rgba(255, 255, 255, 0.1))
    public static let sidebarBackground = themed(light: .hex(0xF9F8F7), dark: .hex(0x202020))
    public static let border = themed(PaletteValues.border)
    /// Линия разделителя на странице: в тёмной теме Notion 7.39 светлее рамок — ≈ rgb(55, 55, 53) по снимку 19.10.2026.
    public static let dividerLine = themed(PaletteValues.dividerLine)
    /// Строка дерева под мышью или выбранная, кнопки при наведении.
    /// Закрашенная «★» избранной страницы в верхней полосе.
    public static let favoriteStar = themed(light: .hex(0xE8A600), dark: .hex(0xF0B72F))
    public static let hoverBackground = themed(light: .rgba(33, 27, 23, 0.05), dark: .rgba(255, 255, 255, 0.055))
    public static let inlineCodeText = themed(PaletteValues.inlineCodeText)
    public static let inlineCodeBackground = themed(PaletteValues.inlineCodeBackground)
    public static let checkboxChecked = themed(PaletteValues.checkboxChecked)
    /// «+», «⋮⋮», стрелки раскрытия.
    /// Жёлтая полоса ошибки сохранения (желтый фон блока Notion, ≈).
    public static let saveErrorBannerBackground = themed(light: .hex(0xFBF3DB), dark: .hex(0x3F3622))
    public static let handleIcon = themed(PaletteValues.handleIcon)
    /// Линия места сброса при перетаскивании блока: синий Notion в обеих темах (по снимку Notion).
    public static let dropIndicator = themed(light: .rgba(35, 131, 226, 0.43), dark: .rgba(35, 131, 226, 0.43))
    /// Выделение текста: синий Notion поверх страницы, текст в выделении своего цвета (по снимку Notion 15.10.2026).
    public static let textSelection = themed(light: .rgba(35, 131, 226, 0.28), dark: .rgba(35, 131, 226, 0.28))
    /// Выделение блоков целиком: тот же синий Notion, вдвое прозрачнее (по снимку Notion 15.10.2026).
    public static let blockSelection = themed(light: .rgba(35, 131, 226, 0.14), dark: .rgba(35, 131, 226, 0.14))
    /// Галочка в отмеченном чекбоксе.
    public static let checkboxCheckmark = themed(PaletteValues.checkboxCheckmark)
    /// Подчёркивание ссылки: ≈ 40 % цвета текста.
    public static let linkUnderline = themed(PaletteValues.linkUnderline)

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
    public static let pageHeaderButton = themed(PaletteValues.pageHeaderButton)
    /// Выключенный переключатель подменю (≈ по Notion).
    public static let switchOff = themed(light: .rgba(135, 131, 120, 0.3), dark: .rgba(202, 196, 182, 0.3))
    /// Заглушка обложки, чья картинка ещё не пришла с другого Mac, и неизвестной обложки галереи (≈ по Notion).
    public static let placeholder = themed(PaletteValues.placeholder)
    /// Кнопки на обложке «Сменить», «Переместить»: тёмная полупрозрачная группа поверх картинки в обеих темах
    /// (снимок Notion 7.39 `notion-cover-hover-buttons.png`).
    public static let coverButtonBackground = NSColor.rgba(25, 25, 25, 0.88)
    public static let coverButtonHover = NSColor.rgba(255, 255, 255, 0.1)
    public static let coverButtonText = NSColor.rgba(255, 255, 255, 0.78)
    public static let coverButtonBorder = NSColor.rgba(255, 255, 255, 0.12)

    /// Тень всплывающих панелей: четыре слоя, последний — тонкая рамка. В тёмной теме тень гуще, а рамка светлая:
    /// тёмная тень на тёмной странице не видна (≈ по Notion).
    /// Тень окон-карточек над страницей (корзина, подтверждение, выдача поиска): со всех сторон, верхний край поверх
    /// текста не выглядит срезом строки (ui-review № 26).
    public static let popupCardShadow: [ShadowLayer] = [
        ShadowLayer(offsetY: 20, blurRadius: 24, spread: 0, color: themed(light: .rgba(25, 25, 25, 0.05), dark: .rgba(0, 0, 0, 0.4))),
        ShadowLayer(offsetY: 5, blurRadius: 8, spread: 0, color: themed(light: .rgba(25, 25, 25, 0.027), dark: .rgba(0, 0, 0, 0.2))),
        ShadowLayer(offsetY: 0, blurRadius: 8, spread: 0, color: themed(light: .rgba(15, 15, 15, 0.1), dark: .rgba(0, 0, 0, 0.6))),
        ShadowLayer(offsetY: 0, blurRadius: 0, spread: 1, color: themed(light: .rgba(42, 28, 0, 0.07), dark: .rgba(255, 255, 255, 0.094))),
    ]

    /// Тень всплывающих меню. Подобрано по снимкам меню Notion 7.39 (19.10.2026): в светлой теме у края светлее, а вниз тянется на ≈ 42;
    /// в тёмной снаружи тени нет — только светлая рамка.
    public static let popupMenuShadow: [ShadowLayer] = [
        ShadowLayer(offsetY: 12, blurRadius: 32, spread: 0, color: themed(light: .rgba(15, 15, 15, 0.06), dark: .rgba(0, 0, 0, 0))),
        ShadowLayer(offsetY: 3, blurRadius: 6, spread: 0, color: themed(light: .rgba(15, 15, 15, 0.03), dark: .rgba(0, 0, 0, 0))),
        ShadowLayer(offsetY: 0, blurRadius: 0, spread: 1, color: themed(light: .rgba(15, 15, 15, 0.05), dark: .rgba(255, 255, 255, 0.13))),
    ]

    private static func themed(_ color: ThemedPaletteColor) -> NSColor {
        themed(light: .palette(color.light), dark: .palette(color.dark))
    }

    private static func themed(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

extension Palette {
    /// Цвет текста Notion; `nil` — основной цвет текста страницы (значения — `PaletteValues`, общие с iPhone).
    public static func notionText(_ tone: NotionTone?) -> NSColor {
        guard let tone else { return textPrimary }
        return notionTextColors[tone] ?? textPrimary
    }

    /// Цвет подложки Notion (фон текста или блока); `nil` — без подложки.
    public static func notionBackground(_ tone: NotionTone?) -> NSColor? {
        guard let tone else { return nil }
        return notionBackgroundColors[tone]
    }

    private static let notionTextColors: [NotionTone: NSColor] = Dictionary(uniqueKeysWithValues: NotionTone.allCases.map {
        // Один цвет на обе темы — обычный, не переключаемый.
        ($0, .palette(PaletteValues.notionText($0).light))
    })

    private static let notionBackgroundColors: [NotionTone: NSColor] = Dictionary(uniqueKeysWithValues: NotionTone.allCases.map {
        ($0, themed(PaletteValues.notionBackground($0)))
    })
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

    fileprivate static func palette(_ color: PaletteRGBA) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    fileprivate static func rgba(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }
}
#endif
