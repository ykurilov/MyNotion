#if canImport(AppKit)
import AppKit

extension Palette {
    /// Плашка под найденным поиском в базе (Notion 7.39, `notion-search-in-database.png`: серая плашка под словом).
    public static let searchMatchBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.16) : NSColor(srgbRed: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.12)
    }

    /// Синий значок активного фильтра и сортировки в строке вида и синяя плашка фильтра (Notion: значок синеет).
    public static let activeViewControl = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 82 / 255, green: 156 / 255, blue: 202 / 255, alpha: 1) : NSColor(srgbRed: 35 / 255, green: 131 / 255, blue: 226 / 255, alpha: 1)
    }
}
#endif
