import Foundation
import NotesCore

/// Окно «Изменить свойство» числа (contracts/property-types.md, «Число: форматы»; `notion-number-formats.png`,
/// `notion-number-show-as-bar.png`): форматы по порядку Notion 7.39, знаки после запятой, «Показывать как».
/// `config.showAs` — `"number"` или `{style: bar|ring, color, divideBy, showNumber}` (data-model.md).
public enum NumberDisplay {
    public struct Format: Sendable, Hashable {
        public let id: String
        public let title: String
        /// Код валюты ISO — серым справа.
        public let code: String?
    }

    /// Форматы окна «Формат числа» по порядку Notion: число, с разделителями, процент, затем валюты.
    public static let formats: [Format] = [
        Format(id: "number", title: "Число", code: nil),
        Format(id: "numberWithSeparators", title: "Число с разделителями", code: nil),
        Format(id: "percent", title: "Процент", code: nil),
    ] + [
        ("dollar", "Доллар США"), ("australianDollar", "Австралийский доллар"), ("canadianDollar", "Канадский доллар"),
        ("singaporeDollar", "Сингапурский доллар"), ("euro", "Евро"), ("pound", "Фунт"), ("yen", "Иена"), ("ruble", "Рубль"),
        ("rupee", "Индийская рупия"), ("won", "Вона"), ("yuan", "Юань"), ("real", "Реал"), ("lira", "Лира"), ("rupiah", "Рупия Индонезии"),
        ("franc", "Франк"), ("hongKongDollar", "Гонконгский доллар"), ("newZealandDollar", "Новозеландский доллар"), ("krona", "Шведская крона"),
        ("norwegianKrone", "Норвежская крона"), ("mexicanPeso", "Мексиканское песо"), ("rand", "Рэнд"), ("newTaiwanDollar", "Новый тайваньский доллар"),
        ("danishKrone", "Датская крона"), ("zloty", "Злотый"), ("baht", "Бат"), ("forint", "Форинт"), ("koruna", "Чешская крона"),
        ("shekel", "Шекель"), ("chileanPeso", "Чилийское песо"), ("philippinePeso", "Филиппинское песо"), ("dirham", "Дирхам"),
        ("colombianPeso", "Колумбийское песо"), ("riyal", "Риял"), ("ringgit", "Ринггит"), ("leu", "Лей"), ("argentinePeso", "Аргентинское песо"),
        ("uruguayanPeso", "Уругвайское песо"), ("peruvianSol", "Перуанский соль"),
    ].map { Format(id: $0.0, title: $0.1, code: NumberType.currencies[$0.0]) }

    public static func format(_ id: String?) -> Format { formats.first { $0.id == id } ?? formats[0] }

    /// «Знаки после запятой»: «По умолчанию» и 0…8.
    public static let decimalChoices: [Int?] = [nil] + Array(0...8)

    public static func decimalsTitle(_ decimals: Int?) -> String { decimals.map(String.init) ?? "По умолчанию" }

    public enum Style: String, Sendable, CaseIterable {
        case number, bar, ring

        public var title: String {
            switch self {
            case .number: "Число"
            case .bar: "Полоса"
            case .ring: "Кольцо"
            }
        }
    }

    public static func style(_ config: JSONValue) -> Style {
        config["showAs"]?["style"]?.string.flatMap(Style.init(rawValue:)) ?? .number
    }

    /// Настройки «Показывать как» при выборе вида: у полосы и кольца — зелёный, «Разделить на 100», число видно.
    public static func showAs(_ style: Style, keeping config: JSONValue) -> JSONValue? {
        guard style != .number else { return nil }
        var showAs = config["showAs"]?.object.map(JSONValue.object) ?? ["color": "green", "divideBy": 100, "showNumber": true]
        showAs["style"] = .string(style.rawValue)
        return showAs
    }

    /// Полоса или кольцо: доля — число / «Разделить на», от 0 до 1. Вид «Число» — `nil`.
    public static func meter(_ number: Double, text: String, config: JSONValue) -> CellPresentation.NumberMeter? {
        let style = style(config)
        guard style != .number, let showAs = config["showAs"] else { return nil }
        let divisor = showAs["divideBy"]?.number ?? 100
        let fraction = divisor > 0 ? min(max(number / divisor, 0), 1) : 0
        return CellPresentation.NumberMeter(fraction: fraction, color: showAs["color"]?.string.flatMap(OptionColor.init(rawValue:)) ?? .green,
                                            isRing: style == .ring, text: showAs["showNumber"]?.bool == false ? nil : text)
    }
}
