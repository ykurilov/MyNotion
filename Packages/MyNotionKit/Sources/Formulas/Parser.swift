/// Разбор формулы рекурсивным спуском по старшинству операторов (contracts/formulas.md, «Синтаксис»):
/// `? :` < `or` < `and` < `== !=` < `> >= < <=` < `+ -` < `* / %` < `^` < `not ! -` < `.` и вызов.
public enum FormulaParser {
    public static func parse(_ source: String) throws -> FormulaExpression {
        var parser = Parser(tokens: try FormulaLexer.tokens(source))
        let expression = try parser.conditional()
        guard case .end = parser.current.kind else { throw FormulaError("Лишнее после конца формулы", at: parser.current.range) }
        return expression
    }

    private struct Parser {
        let tokens: [FormulaToken]
        var position = 0

        var current: FormulaToken { tokens[position] }

        mutating func advance() { if position < tokens.count - 1 { position += 1 } }

        func isSymbol(_ symbol: String) -> Bool { if case .symbol(let value) = current.kind { value == symbol } else { false } }
        func isWord(_ word: String) -> Bool { if case .identifier(let value) = current.kind { value == word } else { false } }

        mutating func expect(_ symbol: String) throws {
            guard isSymbol(symbol) else { throw FormulaError("Ожидалась «\(symbol)»", at: current.range) }
            advance()
        }

        mutating func conditional() throws -> FormulaExpression {
            let condition = try or()
            guard isSymbol("?") else { return condition }
            advance()
            let yes = try conditional()
            try expect(":")
            return .conditional(condition, yes, try conditional())
        }

        mutating func or() throws -> FormulaExpression {
            var left = try and()
            while isSymbol("||") || isWord("or") { advance(); left = .binary("or", left, try and()) }
            return left
        }

        mutating func and() throws -> FormulaExpression {
            var left = try equality()
            while isSymbol("&&") || isWord("and") { advance(); left = .binary("and", left, try equality()) }
            return left
        }

        mutating func equality() throws -> FormulaExpression {
            var left = try comparison()
            while let op = ["==", "!="].first(where: isSymbol) { advance(); left = .binary(op, left, try comparison()) }
            return left
        }

        mutating func comparison() throws -> FormulaExpression {
            var left = try additive()
            while let op = [">=", "<=", ">", "<"].first(where: isSymbol) { advance(); left = .binary(op, left, try additive()) }
            return left
        }

        mutating func additive() throws -> FormulaExpression {
            var left = try multiplicative()
            while let op = ["+", "-"].first(where: isSymbol) { advance(); left = .binary(op, left, try multiplicative()) }
            return left
        }

        mutating func multiplicative() throws -> FormulaExpression {
            var left = try power()
            while let op = ["*", "/", "%"].first(where: isSymbol) { advance(); left = .binary(op, left, try power()) }
            return left
        }

        mutating func power() throws -> FormulaExpression {
            let base = try unary()
            guard isSymbol("^") else { return base }
            advance()
            return .binary("^", base, try power())
        }

        mutating func unary() throws -> FormulaExpression {
            if isSymbol("!") || isWord("not") { advance(); return .unary("not", try unary()) }
            if isSymbol("-") { advance(); return .unary("-", try unary()) }
            return try postfix()
        }

        mutating func postfix() throws -> FormulaExpression {
            var expression = try primary()
            while isSymbol(".") {
                advance()
                guard case .identifier(let name) = current.kind else { throw FormulaError("Ожидалось имя функции после «.»", at: current.range) }
                advance()
                try expect("(")
                expression = .call(name, [expression] + (try arguments()))
            }
            return expression
        }

        /// Аргументы до «)» включительно.
        mutating func arguments() throws -> [FormulaExpression] {
            var result: [FormulaExpression] = []
            if isSymbol(")") { advance(); return result }
            while true {
                result.append(try conditional())
                if isSymbol(")") { advance(); return result }
                try expect(",")
            }
        }

        mutating func primary() throws -> FormulaExpression {
            let token = current
            switch token.kind {
            case .number(let value): advance(); return .number(value)
            case .text(let value): advance(); return .text(value)
            case .identifier(let name):
                advance()
                if name == "true" { return .bool(true) }
                if name == "false" { return .bool(false) }
                if isSymbol("(") { advance(); return .call(name, try arguments()) }
                return .name(name)
            case .symbol("("):
                advance()
                let inner = try conditional()
                try expect(")")
                return inner
            case .symbol("["):
                advance()
                var items: [FormulaExpression] = []
                if isSymbol("]") { advance(); return .list(items) }
                while true {
                    items.append(try conditional())
                    if isSymbol("]") { advance(); return .list(items) }
                    try expect(",")
                }
            case .end: throw FormulaError("Формула оборвалась: ожидалось значение", at: token.range)
            default: throw FormulaError("Ожидалось значение", at: token.range)
            }
        }
    }
}
