/// Слова формулы: числа, тексты, имена, знаки.
struct FormulaToken: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case number(Double)
        case text(String)
        case identifier(String)
        case symbol(String)
        case end
    }

    var kind: Kind
    var range: Range<Int>
}

/// Разбор текста формулы на слова; комментарии `/* … */` и пробелы пропускаются.
enum FormulaLexer {
    static let symbols = ["==", "!=", ">=", "<=", "&&", "||", "(", ")", "[", "]", ",", ".", "!", "-", "+", "*", "/", "%", "^", ">", "<", "?", ":"]

    static func tokens(_ source: String) throws(FormulaError) -> [FormulaToken] {
        let characters = Array(source)
        var tokens: [FormulaToken] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                let start = index
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                guard index + 1 < characters.count else { throw FormulaError("Комментарий не закрыт: ожидалось „*/“", at: start..<characters.count) }
                index += 2
                continue
            }
            if character.isNumber {
                let start = index
                while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
                if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                    var next = index + 1
                    if next < characters.count, characters[next] == "-" || characters[next] == "+" { next += 1 }
                    if next < characters.count, characters[next].isNumber {
                        index = next
                        while index < characters.count, characters[index].isNumber { index += 1 }
                    }
                }
                guard let value = Double(String(characters[start..<index])) else {
                    throw FormulaError("Не число: „\(String(characters[start..<index]))“", at: start..<index)
                }
                tokens.append(FormulaToken(kind: .number(value), range: start..<index))
                continue
            }
            if character == "\"" {
                let start = index
                index += 1
                var text = ""
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        index += 1
                        switch characters[index] {
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        default: text.append(characters[index])
                        }
                    } else {
                        text.append(characters[index])
                    }
                    index += 1
                }
                guard index < characters.count else { throw FormulaError("Текст не закрыт: ожидалась „\"“", at: start..<characters.count) }
                index += 1
                tokens.append(FormulaToken(kind: .text(text), range: start..<index))
                continue
            }
            if character.isLetter || character == "_" {
                let start = index
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" { index += 1 }
                tokens.append(FormulaToken(kind: .identifier(String(characters[start..<index])), range: start..<index))
                continue
            }
            let rest = String(characters[index..<min(index + 2, characters.count)])
            guard let symbol = symbols.first(where: { rest.hasPrefix($0) }) else {
                throw FormulaError("Непонятный знак „\(character)“", at: index..<index + 1)
            }
            tokens.append(FormulaToken(kind: .symbol(symbol), range: index..<index + symbol.count))
            index += symbol.count
        }
        tokens.append(FormulaToken(kind: .end, range: characters.count..<characters.count))
        return tokens
    }
}
