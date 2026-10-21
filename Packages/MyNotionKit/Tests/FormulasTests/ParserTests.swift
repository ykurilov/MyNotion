import Testing
@testable import Formulas

/// Синтаксис формул (contracts/formulas.md, «Синтаксис»): литералы, старшинство, методы и функции, `let`/`lets`,
/// `current`/`index`, комментарии; ошибки с местом и текстом по-русски.
@Suite("Разбор формул")
struct ParserTests {
    func parse(_ source: String) throws -> FormulaExpression { try FormulaParser.parse(source) }

    func error(_ source: String) -> FormulaError? {
        do { _ = try FormulaParser.parse(source); return nil } catch { return error }
    }

    @Test("Литералы: числа, текст с экранированием, флажки, списки")
    func literals() throws {
        #expect(try parse("12") == .number(12))
        #expect(try parse("1.5") == .number(1.5))
        #expect(try parse("2e3") == .number(2000))
        #expect(try parse(#""текст""#) == .text("текст"))
        #expect(try parse(#""он сказал \"да\"\n""#) == .text("он сказал \"да\"\n"))
        #expect(try parse("true") == .bool(true))
        #expect(try parse("false") == .bool(false))
        #expect(try parse("[1, 2, 3]") == .list([.number(1), .number(2), .number(3)]))
        #expect(try parse("[]") == .list([]))
    }

    @Test("Старшинство: * раньше +, ^ справа налево, сравнение раньше and, and раньше or, ? : последним")
    func precedence() throws {
        #expect(try parse("1 + 2 * 3") == .binary("+", .number(1), .binary("*", .number(2), .number(3))))
        #expect(try parse("(1 + 2) * 3") == .binary("*", .binary("+", .number(1), .number(2)), .number(3)))
        #expect(try parse("2 ^ 3 ^ 2") == .binary("^", .number(2), .binary("^", .number(3), .number(2))))
        #expect(try parse("2 * 3 ^ 2") == .binary("*", .number(2), .binary("^", .number(3), .number(2))))
        #expect(try parse("10 - 4 - 3") == .binary("-", .binary("-", .number(10), .number(4)), .number(3)))
        #expect(try parse("1 + 1 == 2 and 3 > 2") == .binary("and", .binary("==", .binary("+", .number(1), .number(1)), .number(2)),
                                                           .binary(">", .number(3), .number(2))))
        #expect(try parse("true or false and false") == .binary("or", .bool(true), .binary("and", .bool(false), .bool(false))))
        #expect(try parse("a || b && c") == parse("a or b and c"))
        #expect(try parse("not true and false") == .binary("and", .unary("not", .bool(true)), .bool(false)))
        #expect(try parse("!true") == .unary("not", .bool(true)))
        #expect(try parse("-2 * 3") == .binary("*", .unary("-", .number(2)), .number(3)))
        #expect(try parse("1 > 2 ? 1 : 2 > 1 ? 2 : 3") == .conditional(.binary(">", .number(1), .number(2)), .number(1),
                                                                        .conditional(.binary(">", .number(2), .number(1)), .number(2), .number(3))))
        #expect(try parse("7 % 3 * 2") == .binary("*", .binary("%", .number(7), .number(3)), .number(2)))
        #expect(try parse("1 != 2 == true") == .binary("==", .binary("!=", .number(1), .number(2)), .bool(true)))
    }

    @Test("Вызов методом равен вызову функцией; цепочка методов")
    func methods() throws {
        #expect(try parse(#"length(prop("Имя"))"#) == parse(#"prop("Имя").length()"#))
        #expect(try parse(#"prop("Проект").map(current.prop("Название")).join(", ")"#)
                == .call("join", [.call("map", [.call("prop", [.text("Проект")]), .call("prop", [.name("current"), .text("Название")])]), .text(", ")]))
        #expect(try parse("[3, 1].sort().first()") == .call("first", [.call("sort", [.list([.number(3), .number(1)])])]))
        #expect(try parse("now()") == .call("now", []))
    }

    @Test("Переменные let/lets, current и index")
    func variables() throws {
        #expect(try parse("let(x, 5, x * 2)") == .call("let", [.name("x"), .number(5), .binary("*", .name("x"), .number(2))]))
        #expect(try parse("lets(a, 1, b, a + 1, b)") == .call("lets", [.name("a"), .number(1), .name("b"), .binary("+", .name("a"), .number(1)), .name("b")]))
        #expect(try parse("map([1], current + index)") == .call("map", [.list([.number(1)]), .binary("+", .name("current"), .name("index"))]))
    }

    @Test("Комментарии, переводы строк и пробелы свободны")
    func commentsAndSpaces() throws {
        #expect(try parse("/* цена */ 1 +\n\t2 /* итог */") == .binary("+", .number(1), .number(2)))
        #expect(try parse("if(\n  true,\n  1,\n  2\n)") == .call("if", [.bool(true), .number(1), .number(2)]))
    }

    @Test("Место узла: вызов, текст свойства, знак")
    func ranges() throws {
        let tree = try parse(#"prop("Срок") + 1"#)
        guard case .binary(_, let left, let right) = tree.kind, case .call(_, let arguments) = left.kind else { Issue.record("не тот разбор"); return }
        #expect(tree.range == 0..<16)
        #expect(left.range == 0..<12)
        #expect(arguments[0].range == 5..<11)
        #expect(right.range == 15..<16)
        let method = try parse(#"prop("A").length()"#)
        #expect(method.range == 0..<18)
    }

    @Test("Ошибки — по-русски и с местом (примеры contracts)")
    func errors() {
        #expect(error("if(true, 1") == FormulaError("Ожидалась „)“", at: 10..<10))
        #expect(error(#"prop("Срок""#) == FormulaError("Ожидалась „)“", at: 11..<11))
        #expect(error("[1, 2") == FormulaError("Ожидалась „]“", at: 5..<5))
        #expect(error("(1 + 2") == FormulaError("Ожидалась „)“", at: 6..<6))
        #expect(error("true ? 1") == FormulaError("Ожидалось „:“", at: 8..<8))
        #expect(error("1 +") == FormulaError("Формула оборвалась: ожидалось значение", at: 3..<3))
        #expect(error("") == FormulaError("Формула оборвалась: ожидалось значение", at: 0..<0))
        #expect(error(#""абв"#) == FormulaError("Текст не закрыт: ожидалась „\"“", at: 0..<4))
        #expect(error("1 # 2") == FormulaError("Непонятный знак „#“", at: 2..<3))
        #expect(error("/* без конца") == FormulaError("Комментарий не закрыт: ожидалось „*/“", at: 0..<12))
        #expect(error("1 2") == FormulaError("Лишнее после конца формулы", at: 2..<3))
        #expect(error("1 + * 2") == FormulaError("Ожидалось значение, а не „*“", at: 4..<5))
        #expect(error("[1].(") == FormulaError("Ожидалось имя функции после „.“", at: 4..<5))
    }
}
