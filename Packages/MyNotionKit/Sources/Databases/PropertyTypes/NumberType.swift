import Foundation
import NotesCore

/// Число: форматы, «знаки после запятой» и «Показывать как» — в `config` (contracts/property-types.md, «Число: форматы»).
struct NumberType: PropertyType {
    let kind = PropertyKind.number
    var filterOperators: [FilterOperator] { FilterOperator.numberOperators }
    var calculations: [Calculation] { Calculation.common + Calculation.numeric }

    /// Валюты форматов Notion — код ISO.
    static let currencies: [String: String] = [
        "dollar": "USD", "australianDollar": "AUD", "canadianDollar": "CAD", "singaporeDollar": "SGD", "euro": "EUR", "pound": "GBP",
        "yen": "JPY", "ruble": "RUB", "rupee": "INR", "won": "KRW", "yuan": "CNY", "real": "BRL", "lira": "TRY", "rupiah": "IDR",
        "franc": "CHF", "hongKongDollar": "HKD", "newZealandDollar": "NZD", "krona": "SEK", "norwegianKrone": "NOK", "mexicanPeso": "MXN",
        "rand": "ZAR", "newTaiwanDollar": "TWD", "danishKrone": "DKK", "zloty": "PLN", "baht": "THB", "forint": "HUF", "koruna": "CZK",
        "shekel": "ILS", "chileanPeso": "CLP", "philippinePeso": "PHP", "dirham": "AED", "colombianPeso": "COP", "riyal": "SAR",
        "ringgit": "MYR", "leu": "RON", "argentinePeso": "ARS", "uruguayanPeso": "UYU", "peruvianSol": "PEN",
    ]

    func comparables(_ value: JSONValue, in context: PropertyContext) -> CellComparables {
        guard let number = value.number else { return CellComparables() }
        return CellComparables(sortNumber: number, searchText: Self.plain(number))
    }

    func displayText(_ value: JSONValue?, in context: PropertyContext) -> String {
        guard let number = value?.number else { return "" }
        return Self.format(number, config: context.config, locale: context.locale)
    }

    static func format(_ number: Double, config: JSONValue, locale: Locale) -> String {
        let formatter = Formatters.number("\(locale.identifier)|\(config["format"]?.string ?? "")|\(config["decimals"]?.number ?? -1)") {
            makeFormatter(config: config, locale: locale)
        }
        return formatter.string(from: NSNumber(value: number)) ?? plain(number)
    }

    private static func makeFormatter(config: JSONValue, locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        let decimals = config["decimals"]?.number.map(Int.init)
        let format = config["format"]?.string ?? "number"
        switch format {
        case "numberWithSeparators":
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
        case "percent":
            formatter.numberStyle = .percent
            formatter.maximumFractionDigits = decimals ?? 8
        default:
            if let code = currencies[format] {
                formatter.numberStyle = .currency
                formatter.currencyCode = code
            } else {
                formatter.numberStyle = .decimal
                formatter.usesGroupingSeparator = false
            }
        }
        if formatter.numberStyle == .decimal { formatter.maximumFractionDigits = decimals ?? 8 }
        if let decimals {
            formatter.minimumFractionDigits = decimals
            formatter.maximumFractionDigits = decimals
        }
        return formatter
    }

    /// Число в CSV: без разделителей групп, точка.
    static func plain(_ number: Double) -> String {
        number.rounded() == number && abs(number) < 1e15 ? String(Int64(number)) : String(number)
    }

    func csvText(_ value: JSONValue?, in context: PropertyContext) -> String {
        guard let number = value?.number else { return "" }
        return context.config["format"]?.string == "percent" ? Self.plain((number * 100 * 1e9).rounded() / 1e9) + "%" : Self.plain(number)
    }

    func parseCSV(_ text: String, in context: PropertyContext) -> CSVValue { .value(Self.parse(text).map(JSONValue.number)) }

    /// Число из текста: точка или запятая, «%» — доля, знаки валют и пробелы отбрасываются.
    static func parse(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isPercent = trimmed.hasSuffix("%")
        trimmed = trimmed.filter { !"%$€£₽¥₹₩ \u{00A0}\u{202F}".contains($0) }
        if !trimmed.contains("."), trimmed.filter({ $0 == "," }).count == 1 { trimmed = trimmed.replacingOccurrences(of: ",", with: ".") }
        trimmed = trimmed.replacingOccurrences(of: ",", with: "")
        guard let number = Double(trimmed), number.isFinite else { return nil }
        return isPercent ? number / 100 : number
    }

    func groupKeys(_ value: JSONValue?, in context: PropertyContext, bucket: JSONValue?) -> [String] {
        guard let number = value?.number else { return [] }
        let from = bucket?["from"]?.number ?? 0, to = bucket?["to"]?.number ?? 1_000, step = max(bucket?["step"]?.number ?? 100, 1e-9)
        if number < from { return ["<" + Self.plain(from)] }
        if number >= to { return [Self.plain(to) + "+"] }
        let start = from + ((number - from) / step).rounded(.down) * step
        return [Self.plain(start) + "-" + Self.plain(min(start + step, to))]
    }
}
