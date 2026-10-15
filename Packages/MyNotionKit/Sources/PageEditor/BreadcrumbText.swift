import AppKit
import SwiftUI
import VisualStyle

/// Путь «Корень / … / Родитель / Страница» в заданную ширину (contracts/visual-style.md, «Страница»).
/// Сначала прячется середина — целыми страницами, от корня вглубь; потом название страницы обрезается
/// по границе слова. Многоточие слов не рубит. «/» между страницами тусклый и с просветами шире пробела, как у Notion.
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

    /// Ширина строки шрифтом пути — с тем же видом «/», что на экране.
    @MainActor
    static func measure(_ text: String) -> Double {
        attributed(text).size().width
    }

    /// Путь для AppKit: названия цвета текста, «/» — `Palette.breadcrumbSeparator`.
    @MainActor
    static func attributed(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for piece in pieces(of: text) {
            var attributes: [NSAttributedString.Key: Any] = [.font: Typography.breadcrumb.font,
                                                             .foregroundColor: piece.isSlash ? Palette.breadcrumbSeparator : Palette.textPrimary]
            if piece.kern != 0 { attributes[.kern] = piece.kern }
            result.append(NSAttributedString(string: piece.text, attributes: attributes))
        }
        return result
    }

    /// Тот же путь для SwiftUI.
    @MainActor
    static func styled(_ text: String) -> AttributedString {
        var result = AttributedString()
        for piece in pieces(of: text) {
            var part = AttributedString(piece.text)
            part.font = Font(Typography.breadcrumb.font)
            part.foregroundColor = Color(nsColor: piece.isSlash ? Palette.breadcrumbSeparator : Palette.textPrimary)
            if piece.kern != 0 { part.kern = piece.kern }
            result += part
        }
        return result
    }

    private struct Piece {
        var text: String
        var isSlash = false
        /// Добавка после знака: у пробела перед «/» и у самой «/» — просветы Notion.
        var kern: CGFloat = 0
    }

    /// Названия, пробел перед «/», «/» и пробел после неё — по отдельности.
    private static func pieces(of text: String) -> [Piece] {
        var pieces: [Piece] = []
        for (index, title) in text.components(separatedBy: separator).enumerated() {
            if index > 0 {
                pieces += [Piece(text: " ", kern: Metrics.Page.breadcrumbSpaceBeforeSeparatorKern),
                           Piece(text: "/", isSlash: true, kern: Metrics.Page.breadcrumbSeparatorKern),
                           Piece(text: " ")]
            }
            if !title.isEmpty { pieces.append(Piece(text: title)) }
        }
        return pieces
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
