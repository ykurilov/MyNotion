import AppKit

/// Цвета светлой и тёмной темы по contracts/visual-style.md. Каждый цвет сам
/// переключается вместе с темой Mac. Других мест с цветами в коде нет.
public enum Palette {
    public static let textPrimary = themed(light: .hex(0x2C2C2B), dark: .hex(0xF0EFED))
    public static let textSecondary = themed(light: .hex(0x7D7A75), dark: .hex(0x9B9A97))
    public static let sidebarText = themed(light: .hex(0x5F5E59), dark: .hex(0x9B9A97))
    public static let pageBackground = themed(light: .hex(0xFFFFFF), dark: .hex(0x191919))
    public static let sidebarBackground = themed(light: .hex(0xF9F8F7), dark: .hex(0x202020))
    public static let border = themed(light: .hex(0xE6E5E3), dark: .hex(0x2F2F2F))
    /// Строка дерева под мышью или выбранная, кнопки при наведении.
    public static let hoverBackground = themed(light: .rgba(33, 27, 23, 0.05), dark: .rgba(255, 255, 255, 0.055))
    public static let inlineCodeText = themed(light: .hex(0xCF5148), dark: .hex(0xCF5148))
    public static let inlineCodeBackground = themed(light: .rgba(33, 27, 23, 0.05), dark: .rgba(255, 255, 255, 0.055))
    public static let checkboxChecked = themed(light: .hex(0x2383E2), dark: .hex(0x2383E2))
    /// «Удалить» в меню блока: надпись и значок.
    public static let destructiveText = themed(light: .hex(0xCF5148), dark: .hex(0xCF5148))
    /// «+», «⋮⋮», стрелки раскрытия.
    /// Жёлтая полоса ошибки сохранения (желтый фон блока Notion, ≈).
    public static let saveErrorBannerBackground = themed(light: .hex(0xFBF3DB), dark: .hex(0x3F3622))
    public static let handleIcon = themed(light: .rgba(55, 53, 47, 0.35), dark: .rgba(255, 255, 255, 0.3))
    /// Линия места сброса при перетаскивании блока (≈ по Notion).
    public static let dropIndicator = themed(light: .rgba(35, 131, 226, 0.43), dark: .rgba(35, 131, 226, 0.6))
    /// Галочка в отмеченном чекбоксе.
    public static let checkboxCheckmark = themed(light: .hex(0xFFFFFF), dark: .hex(0xFFFFFF))
    /// Подчёркивание ссылки: ≈ 40 % цвета текста.
    public static let linkUnderline = themed(
        light: .hex(0x2C2C2B).withAlphaComponent(0.4),
        dark: .hex(0xF0EFED).withAlphaComponent(0.4)
    )

    /// Фон всплывающих меню: в тёмной теме светлее страницы, как в Notion (≈ по Notion).
    public static let popupMenuBackground = themed(light: .hex(0xFFFFFF), dark: .hex(0x252525))

    /// Тень всплывающих меню: три слоя, последний — тонкая рамка. В тёмной теме тень гуще, а рамка светлая:
    /// тёмная тень на тёмной странице не видна (≈ по Notion).
    public static let popupMenuShadow: [ShadowLayer] = [
        ShadowLayer(offsetY: 20, blurRadius: 24, spread: 0, color: themed(light: .rgba(25, 25, 25, 0.05), dark: .rgba(0, 0, 0, 0.4))),
        ShadowLayer(offsetY: 5, blurRadius: 8, spread: 0, color: themed(light: .rgba(25, 25, 25, 0.027), dark: .rgba(0, 0, 0, 0.2))),
        ShadowLayer(offsetY: 0, blurRadius: 0, spread: 1, color: themed(light: .rgba(42, 28, 0, 0.07), dark: .rgba(255, 255, 255, 0.094))),
    ]

    private static func themed(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
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
