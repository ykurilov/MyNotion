/// Маркеры и номера списков по уровням вложенности (contracts/visual-style.md).
public enum ListMarkers {
    private static let bullets = ["•", "◦", "▪"]

    /// `•` → `◦` → `▪`, дальше по кругу.
    public static func bullet(atIndent indent: Int) -> String {
        bullets[indent % bullets.count]
    }

    /// `1.` → `a.` → `i.`, дальше по кругу. `position` начинается с 1.
    public static func number(_ position: Int, atIndent indent: Int) -> String {
        let label = switch indent % 3 {
        case 0: String(position)
        case 1: latinLetters(position)
        default: lowercaseRoman(position)
        }
        return label + "."
    }

    /// 1 → a, 26 → z, 27 → aa.
    private static func latinLetters(_ position: Int) -> String {
        var remaining = max(position, 1)
        var letters: [Character] = []
        while remaining > 0 {
            remaining -= 1
            letters.insert(Character(UnicodeScalar(UInt8(97 + remaining % 26))), at: 0)
            remaining /= 26
        }
        return String(letters)
    }

    private static func lowercaseRoman(_ position: Int) -> String {
        let numerals: [(Int, String)] = [
            (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
            (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ]
        var remaining = max(position, 1)
        var result = ""
        for (value, numeral) in numerals {
            while remaining >= value {
                result += numeral
                remaining -= value
            }
        }
        return result
    }
}
