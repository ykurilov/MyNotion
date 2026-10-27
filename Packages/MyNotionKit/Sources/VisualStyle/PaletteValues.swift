import CoreGraphics

/// Цвет в sRGB, 0…1.
public struct PaletteRGBA: Sendable, Hashable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public static func hex(_ value: UInt32) -> PaletteRGBA {
        PaletteRGBA(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    public static func rgba(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat) -> PaletteRGBA {
        PaletteRGBA(red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }

    public func withAlpha(_ alpha: CGFloat) -> PaletteRGBA {
        PaletteRGBA(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// Цвет светлой и тёмной темы.
public struct ThemedPaletteColor: Sendable, Hashable {
    public let light: PaletteRGBA
    public let dark: PaletteRGBA

    public init(light: PaletteRGBA, dark: PaletteRGBA) {
        self.light = light
        self.dark = dark
    }

    public static func same(_ color: PaletteRGBA) -> ThemedPaletteColor { ThemedPaletteColor(light: color, dark: color) }
}

/// Цвета Notion: девять оттенков (по умолчанию — отсутствие оттенка). Имена те же, что у `NotionColor` в модели.
public enum NotionTone: String, Sendable, Hashable, CaseIterable {
    case gray, brown, orange, yellow, green, blue, purple, pink, red
}

/// Значения цветов страницы, общие для Mac (`Palette`, AppKit) и iPhone (`PhonePalette`, UIKit) — contracts/visual-style.md.
public enum PaletteValues {
    public static let textPrimary = ThemedPaletteColor(light: .hex(0x2C2C2B), dark: .hex(0xF0EFED))
    public static let textSecondary = ThemedPaletteColor(light: .hex(0x7D7A75), dark: .hex(0x9B9A97))
    public static let pageBackground = ThemedPaletteColor(light: .hex(0xFFFFFF), dark: .hex(0x191919))
    public static let border = ThemedPaletteColor(light: .hex(0xE6E5E3), dark: .hex(0x2F2F2F))
    /// Линия разделителя на странице: в тёмной теме Notion 7.39 светлее рамок — ≈ rgb(55, 55, 53) по снимку 19.10.2026.
    public static let dividerLine = ThemedPaletteColor(light: .hex(0xE6E5E3), dark: .hex(0x373735))
    public static let inlineCodeText = ThemedPaletteColor.same(.hex(0xCF5148))
    public static let inlineCodeBackground = ThemedPaletteColor(light: .rgba(33, 27, 23, 0.05), dark: .rgba(255, 255, 255, 0.055))
    public static let checkboxChecked = ThemedPaletteColor.same(.hex(0x2383E2))
    /// Галочка в отмеченном чекбоксе.
    public static let checkboxCheckmark = ThemedPaletteColor.same(.hex(0xFFFFFF))
    /// «+», «⋮⋮», стрелки раскрытия.
    public static let handleIcon = ThemedPaletteColor(light: .rgba(55, 53, 47, 0.35), dark: .rgba(255, 255, 255, 0.3))
    /// Подчёркивание ссылки: ≈ 40 % цвета текста.
    public static let linkUnderline = ThemedPaletteColor(light: textPrimary.light.withAlpha(0.4), dark: textPrimary.dark.withAlpha(0.4))
    /// «Добавить иконку» в шапке страницы: серая надпись и значок (тёмная — по снимку Notion 16.10.2026, светлая ≈).
    public static let pageHeaderButton = ThemedPaletteColor(light: .hex(0x9B9A97), dark: .hex(0x7D7A75))
    /// Заглушка обложки, чья картинка ещё не пришла с другого Mac, и неизвестной обложки галереи (≈ по Notion).
    public static let placeholder = ThemedPaletteColor(light: .hex(0xF1F1EF), dark: .hex(0x2F2F2F))

    /// Цвет текста Notion. Значения сняты с живого Notion 7.39.0 (пиксели заголовков в обеих темах): текст у Notion
    /// в обеих темах один и тот же.
    public static func notionText(_ tone: NotionTone) -> ThemedPaletteColor {
        .same(notionTextColors[tone]!)
    }

    /// Цвет подложки Notion (фон текста или блока). Фон слова и фон блока у Notion одного цвета.
    public static func notionBackground(_ tone: NotionTone) -> ThemedPaletteColor {
        notionBackgroundColors[tone]!
    }

    private static let notionTextColors: [NotionTone: PaletteRGBA] = [
        .gray: .hex(0x7D7A75),
        .brown: .hex(0x9F765A),
        .orange: .hex(0xD27B2D),
        .yellow: .hex(0xCB9434),
        .green: .hex(0x50946E),
        .blue: .hex(0x387DC9),
        .purple: .hex(0x9A6BB4),
        .pink: .hex(0xC14C8A),
        .red: .hex(0xCF5148),
    ]

    private static let notionBackgroundColors: [NotionTone: ThemedPaletteColor] = [
        .gray: ThemedPaletteColor(light: .hex(0xF0EFED), dark: .hex(0x383836)),
        .brown: ThemedPaletteColor(light: .hex(0xF5EDE9), dark: .hex(0x45362D)),
        .orange: ThemedPaletteColor(light: .hex(0xFBEBDE), dark: .hex(0x53361F)),
        .yellow: ThemedPaletteColor(light: .hex(0xF9F3DC), dark: .hex(0x504425)),
        .green: ThemedPaletteColor(light: .hex(0xE8F1EC), dark: .hex(0x263D30)),
        .blue: ThemedPaletteColor(light: .hex(0xE5F2FC), dark: .hex(0x233850)),
        .purple: ThemedPaletteColor(light: .hex(0xF3EBF9), dark: .hex(0x3C2D47)),
        .pink: ThemedPaletteColor(light: .hex(0xFAE9F1), dark: .hex(0x4E2B3C)),
        .red: ThemedPaletteColor(light: .hex(0xFCE9E7), dark: .hex(0x502C29)),
    ]
}
