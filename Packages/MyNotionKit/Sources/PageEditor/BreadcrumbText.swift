import AppKit
import VisualStyle

/// Путь «Корень / … / Родитель / Страница» в заданную ширину (contracts/visual-style.md, «Страница»).
/// Сначала прячется середина — целыми страницами, от корня вглубь; потом название страницы обрезается
/// по границе слова. Многоточие слов не рубит.
enum BreadcrumbText {
    static let separator = " / "
    static let ellipsis = "…"

    static func fitting(_ titles: [String], width: Double, measure: (String) -> Double) -> String {
        guard let current = titles.last else { return "" }
        let full = titles.joined(separator: separator)
        if measure(full) <= width { return full }

        if titles.count > 2 {
            for hidden in 1...(titles.count - 2) {
                let candidate = ([titles[0], ellipsis] + titles[(1 + hidden)...]).joined(separator: separator)
                if measure(candidate) <= width { return candidate }
            }
        }

        // Остались корень и страница — обрезать название; не влезает ни слова — вместо корня «…».
        let prefixes = titles.count > 2 ? [[titles[0], ellipsis], [ellipsis]] : titles.count == 2 ? [[titles[0]], [ellipsis]] : [[]]
        for prefix in prefixes {
            let head = prefix.isEmpty ? "" : prefix.joined(separator: separator) + separator
            if let title = truncatedAtWord(current, width: width - measure(head), measure: measure) {
                return head + title
            }
        }
        let head = prefixes.last!.isEmpty ? "" : ellipsis + separator
        return head + truncatedByCharacter(current, width: width - measure(head), measure: measure)
    }

    /// Ширина строки шрифтом пути.
    @MainActor
    static func measure(_ text: String) -> Double {
        NSAttributedString(string: text, attributes: [.font: Typography.breadcrumb.font]).size().width
    }

    /// Самое длинное начало из целых слов с «…»; `nil` — не влезает и первое слово.
    private static func truncatedAtWord(_ title: String, width: Double, measure: (String) -> Double) -> String? {
        let words = title.split(separator: " ")
        for count in stride(from: words.count - 1, through: 1, by: -1) {
            let start = words[..<count].joined(separator: " ").trimmingCharacters(in: Self.trailingPunctuation)
            guard !start.isEmpty else { continue }
            let candidate = start + ellipsis
            if measure(candidate) <= width { return candidate }
        }
        return nil
    }

    /// Одно длинное слово в очень узком окне: режется по букве — иначе не показать ничего.
    private static func truncatedByCharacter(_ title: String, width: Double, measure: (String) -> Double) -> String {
        var start = title
        while !start.isEmpty, measure(start + ellipsis) > width { start.removeLast() }
        return start + ellipsis
    }

    /// Тире, запятые и пробелы на конце обрезанного названия перед «…» лишние.
    private static let trailingPunctuation = CharacterSet(charactersIn: " —–-,:;")
}
