/// Подсветка текста формулы в редакторе: функции — цветом, тексты, числа, слова языка; свойства `prop("…")` — плашками
/// (contracts/formulas.md, «Редактор»). Места — в символах Swift.
public enum FormulaHighlight {
    public enum Kind: Sendable, Hashable {
        case function
        case text
        case number
        /// `true`, `false`, `and`, `or`, `not`.
        case keyword
        /// `current`, `index`, переменные `let`.
        case variable
        case symbol
    }

    public struct Span: Sendable, Hashable {
        public var range: Range<Int>
        public var kind: Kind
    }

    /// Вызов `prop("…")`: место всего вызова и текст в кавычках.
    public struct PropertyCall: Sendable, Hashable {
        public var range: Range<Int>
        public var key: String
    }

    /// Куски текста по видам; текст с ошибкой разбора слов — пусто.
    public static func spans(_ source: String) -> [Span] {
        guard let tokens = try? FormulaLexer.tokens(source) else { return [] }
        var result: [Span] = []
        for (index, token) in tokens.enumerated() {
            switch token.kind {
            case .number: result.append(Span(range: token.range, kind: .number))
            case .text: result.append(Span(range: token.range, kind: .text))
            case .identifier(let name):
                let isCall = index + 1 < tokens.count && tokens[index + 1].kind == .symbol("(")
                let kind: Kind = ["true", "false", "and", "or", "not"].contains(name) ? .keyword : (isCall ? .function : .variable)
                result.append(Span(range: token.range, kind: kind))
            case .symbol: result.append(Span(range: token.range, kind: .symbol))
            case .end: break
            }
        }
        return result
    }

    /// Все `prop("…")` в тексте (и `current.prop("…")` — только сам вызов).
    public static func propertyCalls(_ source: String) -> [PropertyCall] {
        guard let tokens = try? FormulaLexer.tokens(source) else { return [] }
        var result: [PropertyCall] = []
        for index in tokens.indices where index + 3 < tokens.count {
            guard case .identifier("prop") = tokens[index].kind, tokens[index + 1].kind == .symbol("("),
                  case .text(let key) = tokens[index + 2].kind, tokens[index + 3].kind == .symbol(")") else { continue }
            result.append(PropertyCall(range: tokens[index].range.lowerBound..<tokens[index + 3].range.upperBound, key: key))
        }
        return result
    }

    /// Слово перед кареткой (для поиска в списке редактора): буквы, цифры, «_».
    public static func word(before caret: Int, in source: String) -> (range: Range<Int>, text: String) {
        let characters = Array(source)
        let end = min(max(0, caret), characters.count)
        var start = end
        while start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber || characters[start - 1] == "_" { start -= 1 }
        return (start..<end, String(characters[start..<end]))
    }
}
