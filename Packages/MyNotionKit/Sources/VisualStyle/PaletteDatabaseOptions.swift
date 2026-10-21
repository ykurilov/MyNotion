import AppKit

extension Palette {
    /// Фон плашки варианта выбора и статуса — 10 цветов Notion 7.39 в обеих темах (contracts/property-types.md, «Цвета
    /// вариантов»; ≈ — уточняет US2 по снимкам `visual-reference/`). Имена — как у `OptionColor` в модели.
    public static func optionChipBackground(_ color: String) -> NSColor {
        optionChipBackgrounds[color] ?? optionChipBackgrounds["default"]!
    }

    /// Текст плашки — один на все цвета в теме.
    public static let optionChipText = themedColor(light: NSColor(srgbRed: 50 / 255, green: 48 / 255, blue: 44 / 255, alpha: 1),
                                                   dark: NSColor(white: 1, alpha: 0.81))

    /// Линии сетки базы и шапка колонок.
    public static let databaseGridLine = themedColor(light: NSColor(srgbRed: 233 / 255, green: 233 / 255, blue: 231 / 255, alpha: 1),
                                                     dark: NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2B / 255, alpha: 1))

    private static let optionChipBackgrounds: [String: NSColor] = [
        "default": themedColor(light: rgb(227, 226, 224, 0.5), dark: rgb(90, 90, 90, 0.5)),
        "gray": themedColor(light: rgb(227, 226, 224), dark: rgb(90, 90, 90)),
        "brown": themedColor(light: rgb(238, 224, 218), dark: rgb(96, 59, 44)),
        "orange": themedColor(light: rgb(250, 222, 201), dark: rgb(133, 76, 29)),
        "yellow": themedColor(light: rgb(253, 236, 200), dark: rgb(137, 99, 42)),
        "green": themedColor(light: rgb(219, 237, 219), dark: rgb(43, 89, 63)),
        "blue": themedColor(light: rgb(211, 229, 239), dark: rgb(40, 69, 108)),
        "purple": themedColor(light: rgb(232, 222, 238), dark: rgb(73, 47, 100)),
        "pink": themedColor(light: rgb(245, 224, 233), dark: rgb(105, 49, 76)),
        "red": themedColor(light: rgb(255, 226, 221), dark: rgb(110, 54, 48)),
    ]

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    private static func themedColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}
