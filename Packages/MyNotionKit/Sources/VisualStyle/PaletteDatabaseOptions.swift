import AppKit

extension Palette {
    /// Фон плашки варианта выбора и статуса — 10 цветов Notion 7.39 (contracts/property-types.md, «Цвета вариантов»).
    /// Тёмная тема — пиксели образцов цветов со снимка `visual-reference/notion-select-option-colors.png` (21.10.2026;
    /// фон плашки «Срочно» совпадает с образцом «Orange»). Светлая — ≈ цвета Notion: снимков светлой темы в сверке нет.
    /// Имена — как у `OptionColor` в модели.
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
        "default": themedColor(light: rgb(206, 205, 202, 0.5), dark: rgb(55, 55, 54)),
        "gray": themedColor(light: rgb(227, 226, 224), dark: rgb(104, 103, 98)),
        "brown": themedColor(light: rgb(238, 224, 218), dark: rgb(117, 91, 72)),
        "orange": themedColor(light: rgb(250, 222, 201), dark: rgb(142, 88, 53)),
        "yellow": themedColor(light: rgb(253, 236, 200), dark: rgb(137, 106, 44)),
        "green": themedColor(light: rgb(219, 237, 219), dark: rgb(63, 111, 84)),
        "blue": themedColor(light: rgb(211, 229, 239), dark: rgb(59, 101, 145)),
        "purple": themedColor(light: rgb(232, 222, 238), dark: rgb(110, 84, 130)),
        "pink": themedColor(light: rgb(245, 224, 233), dark: rgb(130, 78, 103)),
        "red": themedColor(light: rgb(255, 226, 221), dark: rgb(152, 79, 73)),
    ]

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    private static func themedColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}
