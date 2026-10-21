/// Разбор формулы рекурсивным спуском по старшинству операторов (contracts/formulas.md, «Синтаксис»):
/// `? :` < `or` < `and` < `== !=` < `> >= < <=` < `+ -` < `* / %` < `^` < `not ! -` < `.` и вызов.
/// Каждый узел помнит место в тексте; ошибка — по-русски с местом.
public enum FormulaParser {
    public static func parse(_ source: String) throws(FormulaError) -> FormulaExpression {
        var parser = Parser(tokens: try FormulaLexer.tokens(source))
        let expression = try parser.conditional()
        guard case .end = parser.current.kind else { throw FormulaError("Лишнее после конца формулы", at: parser.current.range) }
        return expression
    }

    private struct Parser {
        let tokens: [FormulaToken]
        var position = 0

        var current: FormulaToken { tokens[position] }
        var previousEnd: Int { position > 0 ? tokens[position - 1].range.upperBound : 0 }

        mutating func advance() { if position < tokens.count - 1 { position += 1 } }

        func isSymbol(_ symbol: String) -> Bool { if case .symbol(let value) = current.kind { value == symbol } else { false } }
        func isWord(_ word: String) -> Bool { if case .identifier(let value) = current.kind { value == word } else { false } }

        mutating func expect(_ symbol: String) throws(FormulaError) {
            guard isSymbol(symbol) else {
                let verb = symbol == ":" ? "Ожидалось" : "Ожидалась"
                throw FormulaError("\(verb) „\(symbol)“", at: current.range)
            }
            advance()
        }

        func node(_ kind: FormulaExpression.Kind, from start: Int) -> FormulaExpression {
            FormulaExpression(kind, range: start..<max(start, previousEnd))
        }

        mutating func conditional() throws(FormulaError) -> FormulaExpression {
            let condition = try or()
            guard isSymbol("?") else { return condition }
            advance()
            let yes = try conditional()
            try expect(":")
            let no = try conditional()
            return node(.conditional(condition, yes, no), from: condition.range.lowerBound)
        }

        mutating func or() throws(FormulaError) -> FormulaExpression {
            var left = try and()
            while isSymbol("||") || isWord("or") { advance(); let right = try and(); left = node(.binary("or", left, right), from: left.range.lowerBound) }
            return left
        }

        mutating func and() throws(FormulaError) -> FormulaExpression {
            var left = try equality()
            while isSymbol("&&") || isWord("and") {
                advance()
                let right = try equality()
                left = node(.binary("and", left, right), from: left.range.lowerBound)
            }
            return left
        }

        mutating func equality() throws(FormulaError) -> FormulaExpression {
            var left = try comparison()
            while let op = ["==", "!="].first(where: isSymbol) {
                advance()
                let right = try comparison()
                left = node(.binary(op, left, right), from: left.range.lowerBound)
            }
            return left
        }

        mutating func comparison() throws(FormulaError) -> FormulaExpression {
            var left = try additive()
            while let op = [">=", "<=", ">", "<"].first(where: isSymbol) {
                advance()
                let right = try additive()
                left = node(.binary(op, left, right), from: left.range.lowerBound)
            }
            return left
        }

        mutating func additive() throws(FormulaError) -> FormulaExpression {
            var left = try multiplicative()
            while let op = ["+", "-"].first(where: isSymbol) {
                advance()
                let right = try multiplicative()
                left = node(.binary(op, left, right), from: left.range.lowerBound)
            }
            return left
        }

        mutating func multiplicative() throws(FormulaError) -> FormulaExpression {
            var left = try power()
            while let op = ["*", "/", "%"].first(where: isSymbol) {
                advance()
                let right = try power()
                left = node(.binary(op, left, right), from: left.range.lowerBound)
            }
            return left
        }

        /// `^` — справа налево: `2 ^ 3 ^ 2` = `2 ^ 9`.
        mutating func power() throws(FormulaError) -> FormulaExpression {
            let base = try unary()
            guard isSymbol("^") else { return base }
            advance()
            let exponent = try power()
            return node(.binary("^", base, exponent), from: base.range.lowerBound)
        }

        mutating func unary() throws(FormulaError) -> FormulaExpression {
            let start = current.range.lowerBound
            if isSymbol("!") || isWord("not") { advance(); let operand = try unary(); return node(.unary("not", operand), from: start) }
            if isSymbol("-") { advance(); let operand = try unary(); return node(.unary("-", operand), from: start) }
            return try postfix()
        }

        mutating func postfix() throws(FormulaError) -> FormulaExpression {
            var expression = try primary()
            while isSymbol(".") {
                advance()
                guard case .identifier(let name) = current.kind else { throw FormulaError("Ожидалось имя функции после „.“", at: current.range) }
                advance()
                try expect("(")
                let rest = try arguments()
                expression = node(.call(name, [expression] + rest), from: expression.range.lowerBound)
            }
            return expression
        }

        /// Аргументы до «)» включительно.
        mutating func arguments() throws(FormulaError) -> [FormulaExpression] {
            var result: [FormulaExpression] = []
            if isSymbol(")") { advance(); return result }
            while true {
                result.append(try conditional())
                if isSymbol(")") { advance(); return result }
                guard isSymbol(",") else { throw FormulaError("Ожидалась „)“", at: current.range) }
                advance()
            }
        }

        mutating func primary() throws(FormulaError) -> FormulaExpression {
            let token = current
            let start = token.range.lowerBound
            switch token.kind {
            case .number(let value): advance(); return node(.number(value), from: start)
            case .text(let value): advance(); return node(.text(value), from: start)
            case .identifier(let name):
                advance()
                if name == "true" { return node(.bool(true), from: start) }
                if name == "false" { return node(.bool(false), from: start) }
                if isSymbol("(") {
                    advance()
                    let arguments = try arguments()
                    return node(.call(name, arguments), from: start)
                }
                return node(.name(name), from: start)
            case .symbol("("):
                advance()
                let inner = try conditional()
                try expect(")")
                return inner
            case .symbol("["):
                advance()
                var items: [FormulaExpression] = []
                if isSymbol("]") { advance(); return node(.list(items), from: start) }
                while true {
                    items.append(try conditional())
                    if isSymbol("]") { advance(); return node(.list(items), from: start) }
                    guard isSymbol(",") else { throw FormulaError("Ожидалась „]“", at: current.range) }
                    advance()
                }
            case .end: throw FormulaError("Формула оборвалась: ожидалось значение", at: token.range)
            case .symbol(let symbol): throw FormulaError("Ожидалось значение, а не „\(symbol)“", at: token.range)
            }
        }
    }
}
