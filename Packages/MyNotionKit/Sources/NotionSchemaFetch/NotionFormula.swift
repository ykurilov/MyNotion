import Formulas
import Foundation

/// Формулы Notion 2.0 → язык MyNotion. Язык один, поэтому текст остаётся как есть; меняются только ссылки на свойства:
/// `{{notion:block_property:…}}` становится `prop("Название")`, а название в хранении — id (`FormulaSource.stored`).
public enum NotionFormula {
    public enum Outcome: Sendable, Equatable {
        /// `stored` кладётся в свойство, `display` показывается в редакторе.
        case translated(stored: String, display: String)
        /// Причина по-русски — в строку отчёта импорта.
        case notTranslated(reason: String)
    }

    /// - Parameter propertyNamesById: названия свойств по id (без процентного кодирования) для ссылок `block_property`.
    public static func translate(_ expression: String, propertyNamesById: [String: String], schema: any FormulaSchema) -> Outcome {
        guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .notTranslated(reason: "формула пустая") }
        let display: String
        switch namedReferences(in: expression, propertyNamesById: propertyNamesById) {
        case .success(let text): display = text
        case .failure(let reason): return .notTranslated(reason: reason)
        }
        do {
            return .translated(stored: try FormulaSource.stored(display, schema: schema), display: display)
        } catch {
            return .notTranslated(reason: error.message)
        }
    }

    private enum Replacement {
        case success(String)
        case failure(String)
    }

    private static let blockProperty = try! NSRegularExpression(pattern: #"\{\{notion:block_property:(.+?):[0-9a-fA-F-]{36}:[^:}]+\}\}"#)

    private static func namedReferences(in expression: String, propertyNamesById: [String: String]) -> Replacement {
        let whole = NSRange(expression.startIndex..., in: expression)
        var result = ""
        var cursor = expression.startIndex
        for match in blockProperty.matches(in: expression, range: whole) {
            guard let token = Range(match.range, in: expression), let idRange = Range(match.range(at: 1), in: expression) else { continue }
            let raw = String(expression[idRange])
            guard let name = propertyNamesById[raw.removingPercentEncoding ?? raw] ?? propertyNamesById[raw] else {
                return .failure("в формуле ссылка на свойство, которого нет в схеме базы")
            }
            result += expression[cursor..<token.lowerBound] + "prop(" + FormulaSource.quoted(name) + ")"
            cursor = token.upperBound
        }
        return .success(result + expression[cursor...])
    }
}
