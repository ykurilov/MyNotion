import Testing
@testable import Formulas

/// Вывод типа итога и ошибки типов (contracts/formulas.md, «Итог», «Редактор»), круг «Итог → Сумма → Итог»,
/// названия свойств ↔ id в тексте формулы.
@Suite("Типы формул")
struct TypeCheckTests {
    let schema = FormulaSchemaFixture()

    func type(_ source: String, owner: String? = nil) throws -> FormulaType {
        try FormulaTypeChecker.check(source, schema: schema, owner: owner.map(schema.owner)).type
    }

    func error(_ source: String, owner: String? = nil) -> FormulaError? {
        do { _ = try FormulaTypeChecker.check(source, schema: schema, owner: owner.map(schema.owner)); return nil } catch { return error }
    }

    @Test("Тип итога: литералы, знаки, свойства, функции, связи, переменные")
    func resultTypes() throws {
        #expect(try type("1 + 2") == .number)
        #expect(try type(#""a" + 1"#) == .text)
        #expect(try type("1 > 2") == .bool)
        #expect(try type(#"prop("Готово")"#) == .bool)
        #expect(try type(#"prop("Срок")"#) == .date)
        #expect(try type(#"prop("Теги")"#) == .list(.text))
        #expect(try type(#"prop("Проект")"#) == .list(.page(database: "projects")))
        #expect(try type(#"prop("Проект").map(current.prop("Название"))"#) == .list(.text))
        #expect(try type(#"prop("Проект").map(current.prop("Бюджет")).sum()"#) == .number)
        #expect(try type(#"prop("Проект").first()"#) == .page(database: "projects"))
        #expect(try type(#"dateBetween(prop("Срок"), now(), "days")"#) == .number)
        #expect(try type(#"if(prop("Готово"), "✅", "⏳")"#) == .text)
        #expect(try type(#"prop("Цена") * 1.2"#) == .number)
        #expect(try type(#"prop("Проект").map(current.prop("Название")).join(", ")"#) == .text)
        #expect(try type(#"if(true, 1, "a")"#) == .any, "ветки разных типов — неизвестно")
        #expect(try type("[]") == .list(.any))
        #expect(try type("let(x, 5, x * 2)") == .number)
        #expect(try type(#"lets(a, "x", b, a.length(), b > 0)"#) == .bool)
        #expect(try type("now()") == .date)
        #expect(try type("[1, 2].filter(current > index)") == .list(.number))
        #expect(try type("[[1], [2]].flat()") == .list(.number))
        #expect(try type(#"prop("Метка")"#) == .text, "тип формулы — из её текста")
        #expect(try type(#"format(prop("Срок"))"#) == .text)
    }

    @Test("Ошибки типов — по-русски и с местом (примеры contracts)")
    func typeErrors() {
        #expect(error(#"dateBetween("2026", now(), "days")"#) == FormulaError("Функция dateBetween ждёт дату, а получила текст", at: 12..<18))
        #expect(error(#"style("a", "red")"#) == FormulaError("Функция style не поддерживается в MyNotion", at: 0..<17))
        #expect(error(#"prop("Срок2")"#) == FormulaError("Нет свойства „Срок2“", at: 5..<12))
        #expect(error(#"prop("Автор")"#) == FormulaError("Свойство „Автор“ не поддерживается в MyNotion", at: 5..<12))
        #expect(error(#"1 - "a""#) == FormulaError("Знак „-“ ждёт число, а получил текст", at: 4..<7))
        #expect(error(#"prop("Готово") + 1"#) == FormulaError("Знак „+“ ждёт число или текст, а получил флажок", at: 0..<14))
        #expect(error("if(true, 1)") == FormulaError("Функция if ждёт 3 значения, а получила 2", at: 0..<11))
        #expect(error("abs(1, 2)") == FormulaError("Функция abs ждёт 1 значение, а получила 2", at: 0..<9))
        #expect(error("round()") == FormulaError("Функция round ждёт от 1 до 2 значений, а получила 0", at: 0..<7))
        #expect(error(#"sum("a")"#) == FormulaError("Функция sum ждёт число или список чисел, а получила текст", at: 4..<7))
        #expect(error("current + 1") == FormulaError("„current“ есть только внутри map, filter, find, some, every и sort", at: 0..<7))
        #expect(error("x + 1") == FormulaError("Неизвестное имя „x“", at: 0..<1))
        #expect(error(#"[1].map(current.prop("Название"))"#) == FormulaError("prop у значения ждёт страницу, а получил число", at: 8..<15))
        #expect(error(#"prop("Проект").map(current.prop("Цвет"))"#) == FormulaError("Нет свойства „Цвет“", at: 32..<38))
        #expect(error(#"length(now())"#) == FormulaError("Функция length ждёт текст или список, а получила дату", at: 7..<12))
        #expect(error(#"prop("Срок") > 1"#) == FormulaError("Знак „>“ сравнивает значения одного типа: дата и число", at: 15..<16))
        #expect(error("ifs(true, 1, false, 2)") == FormulaError("Функция ifs ждёт пары «условие, значение» и значение «иначе» в конце", at: 0..<22))
    }

    @Test("Круг формул: «Итог → Сумма → Итог» и сама на себя")
    func cycles() {
        #expect(error(#"prop("Сумма") + 1"#, owner: "Итог") == FormulaError("Формула ссылается сама на себя: Итог → Сумма → Итог", at: 5..<12))
        #expect(error(#"prop("Итог") * 2"#, owner: "Сумма") == FormulaError("Формула ссылается сама на себя: Сумма → Итог → Сумма", at: 5..<11))
        #expect(error(#"prop("Метка") + prop("Итог")"#, owner: "Метка") == FormulaError("Формула ссылается сама на себя: Метка → Метка", at: 5..<12))
        #expect(error(#"prop("Метка")"#, owner: "Итог") == nil, "не круг: Итог → Метка")
    }

    @Test("Названия ↔ id: хранится id, редактор показывает название; переименование не ломает формулу")
    func source() throws {
        let display = #"prop("Проект").map(current.prop("Название")).join(", ") + prop("Цена")"#
        let stored = try FormulaSource.stored(display, schema: schema)
        #expect(stored == #"prop("id-project").map(current.prop("pid-name")).join(", ") + prop("id-price")"#)
        #expect(FormulaSource.display(stored, schema: schema) == display)
        var renamed = schema
        renamed.tasks[3].name = "Стоимость \"с НДС\""
        #expect(FormulaSource.display(stored, schema: renamed) == #"prop("Проект").map(current.prop("Название")).join(", ") + prop("Стоимость \"с НДС\"")"#)
        #expect(try FormulaSource.stored(FormulaSource.display(stored, schema: renamed), schema: renamed) == stored)
        // Удалённое свойство: остальное показывается названиями, удалённое — как было.
        var deleted = schema
        deleted.tasks.remove(at: 3)
        #expect(FormulaSource.display(stored, schema: deleted) == #"prop("Проект").map(current.prop("pid-name")).join(", ") + prop("id-price")"#)
        #expect(throws: FormulaError("Нет свойства „id-price“", at: 67..<77)) { try FormulaSource.stored(stored, schema: deleted) }
    }
}
