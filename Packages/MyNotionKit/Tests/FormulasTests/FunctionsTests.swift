import Foundation
import Testing
@testable import Formulas

/// Функции формул (contracts/formulas.md, «Функции»): каждая — по примерам из описания редактора, крайние случаи,
/// пустое и деление на ноль — пусто, неподдержанная — ошибка с названием; итоги сверяются с подсчётом «в лоб».
@Suite("Функции формул")
struct FunctionsTests {
    let row = FormulaFixture(values: [
        "Срок": FormulaFixture().day(2026, 10, 31),
        "Готово": .bool(true),
        "Цена": .number(1_000),
        "Пусто": .empty,
        "Теги": .list([.text("работа"), .text("срочно")]),
        "Проект": .list([.page(FormulaFixture.projectA), .page(FormulaFixture.projectB)]),
        "Имя": .text("Купить молоко"),
    ])

    /// Все функции из contracts/formulas.md.
    static let contractFunctions = """
        if ifs and or not empty equal unequal \
        add subtract multiply divide mod pow abs round ceil floor sqrt cbrt exp ln log10 log2 sign min max sum mean median pi e toNumber \
        length concat join split substring contains startsWith endsWith lower upper trim repeat padStart padEnd replace replaceAll test match format \
        now today minute hour day date week month year dateAdd dateSubtract dateBetween dateRange dateStart dateEnd timestamp fromTimestamp formatDate parseDate \
        at first last slice sort reverse unique includes find findIndex filter map some every flat \
        prop id let lets
        """.split(separator: " ").map(String.init)

    @Test("Каталог: есть каждая функция contracts, у каждой — синтаксис, описание и пример")
    func catalogCoversContract() {
        for name in Self.contractFunctions {
            let info = FormulaFunctionCatalog.byName[name]
            #expect(info != nil, "нет функции \(name)")
            #expect(!(info?.summary.isEmpty ?? true), "\(name): нет описания")
            if name != "prop" { #expect(!(info?.examples.isEmpty ?? true), "\(name): нет примера") }
        }
        for section in FormulaSection.allCases { #expect(!FormulaFunctionCatalog.functions(in: section).isEmpty, "пустой раздел \(section)") }
        #expect(FormulaFunctionCatalog.functions(in: .lists).contains { $0.name == "sum" }, "sum — и в «Числа», и в «Списки»")
    }

    @Test("Каждый пример из описания функции даёт свой итог", arguments: FormulaFunctionCatalog.all.flatMap { info in info.examples.map { (info.name, $0) } })
    func examples(_ name: String, _ example: FormulaExample) throws {
        #expect(try row.text(example.formula) == example.result, "\(name): \(example.formula)")
    }

    @Test("Примеры «Встроенных» (знаки) дают свой итог", arguments: FormulaFunctionCatalog.builtins.flatMap(\.examples))
    func builtinExamples(_ example: FormulaExample) throws {
        #expect(try row.text(example.formula) == example.result, "\(example.formula)")
    }

    @Test("Формулы из spec, US5")
    func specFormulas() throws {
        #expect(try row.evaluate(#"dateBetween(prop("Срок"), now(), "days")"#) == .number(9))
        #expect(try row.evaluate(#"if(prop("Готово"), "✅", "⏳")"#) == .text("✅"))
        #expect(try FormulaFixture(values: ["Готово": .bool(false)]).evaluate(#"if(prop("Готово"), "✅", "⏳")"#) == .text("⏳"))
        #expect(try row.evaluate(#"prop("Цена") * 1.2"#) == .number(1_200))
        #expect(try row.evaluate(#"prop("Проект").map(current.prop("Название")).join(", ")"#) == .text("Альфа, Бета"))
        #expect(try row.evaluate(#"prop("Проект").map(current.prop("Бюджет")).sum()"#) == .number(350))
        #expect(try row.evaluate(#"prop("Проект").filter(current.prop("Бюджет") > 200).length()"#) == .number(1))
    }

    @Test("Пустое в арифметике, деление на ноль, toNumber(\"abc\"), корень из отрицательного — пусто без ошибки")
    func emptyResults() throws {
        #expect(try row.evaluate(#"prop("Пусто") + 1"#) == .empty)
        #expect(try row.evaluate(#"prop("Пусто") * 2"#) == .empty)
        #expect(try row.evaluate(#"-prop("Пусто")"#) == .empty)
        #expect(try row.evaluate("1 / 0") == .empty)
        #expect(try row.evaluate("divide(1, 0)") == .empty)
        #expect(try row.evaluate("5 % 0") == .empty)
        #expect(try row.evaluate(#"toNumber("abc")"#) == .empty)
        #expect(try row.evaluate(#"toNumber("")"#) == .empty)
        #expect(try row.evaluate("sqrt(-1)") == .empty)
        #expect(try row.evaluate("ln(0)") == .empty)
        #expect(try row.evaluate("pow(10, 400)") == .empty)
        #expect(try row.evaluate(#"abs(prop("Пусто"))"#) == .empty)
        #expect(try row.evaluate(#"dateBetween(prop("Пусто"), now(), "days")"#) == .empty)
        #expect(try row.evaluate(#"prop("Нет такого")"#) == .empty)
    }

    @Test("Ошибка вычисления в строке — пустая ячейка; в редакторе — текст ошибки")
    func rowErrors() throws {
        #expect(throws: FormulaError.self) { try row.evaluate("at([1, 2], 5)") }
        #expect(try row.cell("at([1, 2], 5)") == .empty)
        #expect(throws: FormulaError.self) { try row.evaluate(#"parseDate("вчера")"#) }
        #expect(try row.cell(#"test("a", "(")"#) == .empty)
        #expect(throws: FormulaError.self) { try row.evaluate(#"dateAdd(now(), 1, "век")"#) }
        do { _ = try row.evaluate("at([1, 2], 5)"); Issue.record("нет ошибки") } catch let error as FormulaError {
            #expect(error.message == "Номер 5 за пределами списка из 2")
            #expect(error.range == 0..<13)
        }
    }

    @Test("Неподдержанная функция — ошибка с названием")
    func unsupported() throws {
        for name in ["style", "unstyle", "link", "name", "email"] {
            do { _ = try row.evaluate(#"\#(name)("a")"#); Issue.record("\(name) без ошибки") } catch let error as FormulaError {
                #expect(error.message == "Функция \(name) не поддерживается в MyNotion")
            }
        }
    }

    @Test("Логика: if/ifs вычисляют только нужную ветку, and/or/not, empty")
    func logic() throws {
        #expect(try row.evaluate("if(true, 1, at([], 0))") == .number(1), "ветка «нет» не вычисляется")
        #expect(try row.evaluate("ifs(false, at([], 0), true, 2, 3)") == .number(2))
        #expect(try row.evaluate("false and at([], 0)") == .bool(false))
        #expect(try row.evaluate("true or at([], 0)") == .bool(true))
        #expect(try row.evaluate("and(true, true, false)") == .bool(false))
        #expect(try row.evaluate("or(false, false, true)") == .bool(true))
        for value in [#""""#, "0", "[]", "false", #"prop("Пусто")"#] { #expect(try row.evaluate("empty(\(value))") == .bool(true), "empty(\(value))") }
        for value in [#""а""#, "1", "[0]", "true", "now()"] { #expect(try row.evaluate("empty(\(value))") == .bool(false), "empty(\(value))") }
        #expect(try row.evaluate("equal([1, 2], [1, 2])") == .bool(true))
        #expect(try row.evaluate(#"1 == "1""#) == .bool(false))
    }

    @Test("Числа: округление как в JavaScript, знаки, итоги")
    func numbers() throws {
        #expect(try row.evaluate("round(2.5)") == .number(3))
        #expect(try row.evaluate("round(-2.5)") == .number(-2))
        #expect(try row.evaluate("round(1234.5678, -2)") == .number(1200))
        #expect(try row.evaluate("round(0.125, 2)") == .number(0.13))
        #expect(try row.evaluate("-7 % 3") == .number(-1))
        #expect(try row.evaluate("2 ^ 0.5") == .number(2.0.squareRoot()))
        #expect(try row.evaluate("sum([])") == .number(0))
        #expect(try row.evaluate("mean([])") == .empty)
        #expect(try row.evaluate("min([])") == .empty)
        #expect(try row.evaluate(#"sum(1, prop("Пусто"), [2, 3])"#) == .number(6))
        #expect(try row.evaluate(#"toNumber(" 42 ")"#) == .number(42))
        #expect(try row.evaluate("toNumber(false)") == .number(0))
        #expect(try row.evaluate(#"toNumber(parseDate("1970-01-02T00:00Z"))"#) == .number(86_400_000))
        #expect(try row.text("1 / 3") == "0.3333333333333333")
        #expect(try row.text("0.1 + 0.2") == "0.30000000000000004")
        #expect(try row.text("1e21") == "1e+21")
    }

    @Test("Текст: склейка с числом, длина, части, регистр, шаблоны")
    func text() throws {
        #expect(try row.evaluate(#""Цена: " + prop("Цена")"#) == .text("Цена: 1000"))
        #expect(try row.evaluate(#"1 + "1""#) == .text("11"))
        #expect(try row.evaluate(#""флажок " + true"#) == .text("флажок true"))
        #expect(try row.evaluate(#"prop("Имя").length()"#) == .number(13))
        #expect(try row.evaluate(#"length("")"#) == .number(0))
        #expect(try row.evaluate(#"substring("Notion", 4, 1)"#) == .text("oti"), "«от» больше «до» — меняются местами")
        #expect(try row.evaluate(#"substring("Notion", -3, 2)"#) == .text("No"))
        #expect(try row.evaluate(#"substring("Notion", 10)"#) == .text(""))
        #expect(try row.evaluate(#"split("abc", "")"#) == .list([.text("a"), .text("b"), .text("c")]))
        #expect(try row.evaluate(#"split("", ",")"#) == .list([.text("")]))
        #expect(try row.evaluate(#"contains(prop("Теги"), "срочно")"#) == .bool(true))
        #expect(try row.evaluate(#"contains("abc", "")"#) == .bool(true))
        #expect(try row.evaluate(#"upper("ёлка")"#) == .text("ЁЛКА"))
        #expect(try row.evaluate(#"padStart("12345", 3, "0")"#) == .text("12345"))
        #expect(try row.evaluate(#"padStart("7", 5, "ab")"#) == .text("abab7"))
        #expect(try row.evaluate(#"replace("2026-10-21", "(\\d+)-(\\d+)-(\\d+)", "$3.$2.$1")"#) == .text("21.10.2026"))
        #expect(try row.evaluate(#"replaceAll("a.b.c", "\\.", "/")"#) == .text("a/b/c"))
        #expect(try row.evaluate(#"replace("abc", "x", "y")"#) == .text("abc"))
        #expect(try row.evaluate(#"test(123, "^\\d+$")"#) == .bool(true))
        #expect(try row.evaluate(#"match("нет цифр", "\\d")"#) == .list([]))
        #expect(try row.evaluate(#"join(prop("Теги"), " + ")"#) == .text("работа + срочно"))
        #expect(try row.evaluate(#"join([], ", ")"#) == .text(""))
        #expect(try row.evaluate(#"concat(prop("Теги"), ["новое"])"#) == .list([.text("работа"), .text("срочно"), .text("новое")]))
        #expect(try row.evaluate(#"format(prop("Проект"))"#) == .text("Альфа,Бета"))
        #expect(try row.evaluate(#"format(prop("Срок"))"#) == .text("October 31, 2026"))
        #expect(try row.evaluate(#"repeat("-", 0)"#) == .text(""))
    }

    @Test("Даты: части, сдвиги с концом месяца, разница, диапазон, шаблоны на языке macOS")
    func dates() throws {
        #expect(try row.evaluate("minute(now())") == .number(56))
        #expect(try row.evaluate("hour(now())") == .number(17))
        #expect(try row.evaluate("day(now())") == .number(3), "21.10.2026 — среда")
        #expect(try row.evaluate(#"day(parseDate("2026-10-25"))"#) == .number(0), "воскресенье — 0")
        #expect(try row.evaluate(#"week(parseDate("2027-01-01"))"#) == .number(53))
        #expect(try row.evaluate(#"week(parseDate("2026-01-01"))"#) == .number(1))
        #expect(try row.evaluate("today()") == row.day(2026, 10, 21))
        #expect(try row.evaluate(#"dateAdd(parseDate("2026-01-31"), 1, "months")"#) == row.day(2026, 2, 28))
        #expect(try row.evaluate(#"dateAdd(parseDate("2026-10-21"), 1, "quarters")"#) == row.day(2027, 1, 21))
        #expect(try row.evaluate(#"dateAdd(parseDate("2026-10-21T10:00"), 90, "minutes")"#) == row.day(2026, 10, 21, 11, 30))
        #expect(try row.evaluate(#"dateSubtract(parseDate("2026-03-01"), 1, "days")"#) == row.day(2026, 2, 28))
        #expect(try row.evaluate(#"dateBetween(parseDate("2026-10-21T10:00"), parseDate("2026-10-20T11:00"), "days")"#) == .number(0),
                "23 часа — ноль целых дней")
        #expect(try row.evaluate(#"dateBetween(parseDate("2026-10-20"), parseDate("2026-10-21T12:00"), "hours")"#) == .number(-36))
        #expect(try row.evaluate(#"dateBetween(parseDate("2027-04-01"), parseDate("2026-10-01"), "quarters")"#) == .number(2))
        #expect(try row.evaluate(#"dateBetween(parseDate("2026-10-21"), parseDate("2025-10-22"), "years")"#) == .number(0))
        #expect(try row.evaluate(#"dateEnd(parseDate("2026-10-21"))"#) == row.day(2026, 10, 21))
        #expect(try row.evaluate(#"formatDate(parseDate("2026-10-21"), "D MMMM YYYY")"#) == .text("21 октября 2026"))
        #expect(try row.evaluate(#"formatDate(parseDate("2026-10-21"), "MMMM YYYY")"#) == .text("октябрь 2026"))
        #expect(try row.evaluate(#"formatDate(parseDate("2026-10-21"), "dddd, Q [квартал]")"#) == .text("среда, 4 квартал"))
        #expect(try row.evaluate(#"formatDate(parseDate("2026-10-21T09:05:07"), "h:mm:ss A, YY")"#) == .text("9:05:07 AM, 26"))
        #expect(try row.evaluate(#"formatDate(parseDate("2026-10-21T00:30"), "hh a")"#) == .text("12 am"))
        #expect(try row.evaluate(#"parseDate("2026-10-21T12:00+03:00")"#) == row.day(2026, 10, 21, 12))
        #expect(throws: FormulaError.self) { try row.evaluate(#"parseDate("2026-13-01")"#) }
        #expect(try row.evaluate(#"timestamp(fromTimestamp(timestamp(prop("Срок"))))"#) == row.evaluate(#"timestamp(prop("Срок"))"#))
        #expect(try row.evaluate(#"now() > prop("Срок")"#) == .bool(false))
    }

    @Test("Списки: номера с конца, сортировка устойчивая и по выражению, current и index")
    func lists() throws {
        #expect(try row.evaluate("first([])") == .empty)
        #expect(try row.evaluate("last([])") == .empty)
        #expect(try row.evaluate("slice([1, 2, 3], 2, 1)") == .list([]))
        #expect(try row.evaluate("slice([1, 2, 3], -10, 10)") == .list([.number(1), .number(2), .number(3)]))
        #expect(try row.evaluate(#"sort(["б", "а", "в"])"#) == .list([.text("а"), .text("б"), .text("в")]))
        #expect(try row.evaluate(#"sort([2, 1], 0)"#) == .list([.number(2), .number(1)]), "равные ключи — прежний порядок")
        #expect(try row.evaluate(#"prop("Проект").sort(current.prop("Бюджет")).reverse().map(current.prop("Название"))"#)
                == .list([.text("Бета"), .text("Альфа")]))
        #expect(try row.evaluate("map([10, 20], current + index)") == .list([.number(10), .number(21)]))
        #expect(try row.evaluate("map([[1, 2], [3]], current.length())") == .list([.number(2), .number(1)]))
        #expect(try row.evaluate("map([1, 2], map([10, 20], current))") == .list([.list([.number(10), .number(20)]), .list([.number(10), .number(20)])]),
                "внутренний current — свой")
        #expect(try row.evaluate("find([1, 2], current > 5)") == .empty)
        #expect(try row.evaluate("some([], true)") == .bool(false))
        #expect(try row.evaluate("every([], false)") == .bool(true))
        #expect(try row.evaluate("flat([1, [2, [3]]])") == .list([.number(1), .number(2), .list([.number(3)])]))
        #expect(try row.evaluate(#"includes(prop("Теги"), "работа")"#) == .bool(true))
        #expect(try row.evaluate("let(x, [1, 2], x.length() + x.first())") == .number(3))
        #expect(try row.evaluate("lets(a, 2, b, a * a, c, b + a, [a, b, c])") == .list([.number(2), .number(4), .number(6)]))
    }

    @Test("Страницы: id строки и страницы из связи")
    func pages() throws {
        #expect(try row.evaluate("id()") == .text("00000000000000000000000000000001"))
        #expect(try row.evaluate(#"prop("Проект").first().id()"#) == .text("0000000000000000000000000000000a"))
    }

    @Test("Итоги над случайными списками — как подсчёт «в лоб»")
    func bruteForce() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let numbers = (0..<Int.random(in: 1...30, using: &generator)).map { _ in Double(Int.random(in: -1_000...1_000, using: &generator)) / 4 }
            let literal = "[" + numbers.map { FormulaText.number($0) }.joined(separator: ", ") + "]"
            let sorted = numbers.sorted()
            #expect(try row.evaluate("sum(\(literal))") == .number(numbers.reduce(0, +)))
            #expect(try row.evaluate("min(\(literal))") == .number(sorted.first!))
            #expect(try row.evaluate("max(\(literal))") == .number(sorted.last!))
            #expect(try row.evaluate("mean(\(literal))") == .number(numbers.reduce(0, +) / Double(numbers.count)))
            let middle = sorted.count / 2
            #expect(try row.evaluate("median(\(literal))") == .number(sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2))
            #expect(try row.evaluate("sort(\(literal))") == .list(sorted.map(FormulaValue.number)))
            #expect(try row.evaluate("\(literal).filter(current > 0).length()") == .number(Double(numbers.filter { $0 > 0 }.count)))
            #expect(try row.evaluate("\(literal).map(round(current))") == .list(numbers.map { .number(($0 + 0.5).rounded(.down)) }))
            var seen: Set<Double> = []
            #expect(try row.evaluate("unique(\(literal))") == .list(numbers.filter { seen.insert($0).inserted }.map(FormulaValue.number)))
        }
    }
}
