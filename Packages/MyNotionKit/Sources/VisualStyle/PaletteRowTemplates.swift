#if canImport(AppKit)
import AppKit

/// Шаблоны строк баз (US6): янтарная полоса «Вы правите шаблон в «…»» над шаблоном и синие метки «Быстрого выбора»
/// даты (`notion-template-editor.png`, `notion-template-date-shortcuts-picker.png`).
extension Palette {
    public static let templateBannerBackground = rowTemplateColor(light: NSColor(srgbRed: 0xFB / 255, green: 0xF3 / 255, blue: 0xDB / 255, alpha: 1),
                                                                  dark: NSColor(srgbRed: 0x5C / 255, green: 0x4B / 255, blue: 0x1F / 255, alpha: 1))
    public static let templateBannerText = rowTemplateColor(light: NSColor(srgbRed: 0x9F / 255, green: 0x6B / 255, blue: 0x1F / 255, alpha: 1),
                                                            dark: NSColor(srgbRed: 0xF0 / 255, green: 0xC2 / 255, blue: 0x62 / 255, alpha: 1))
    public static let dateShortcutBackground = rowTemplateColor(light: NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 0.14),
                                                                dark: NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 0.28))
    public static let dateShortcutText = rowTemplateColor(light: NSColor(srgbRed: 0x23 / 255, green: 0x83 / 255, blue: 0xE2 / 255, alpha: 1),
                                                          dark: NSColor(srgbRed: 0x5A / 255, green: 0xA6 / 255, blue: 0xF0 / 255, alpha: 1))

    private static func rowTemplateColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}
#endif
