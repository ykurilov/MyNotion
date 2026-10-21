extension FormulaFunctions {
    /// Элементы с `current` и `index` для выражения (map, filter …).
    private static func each<T>(_ arguments: [FormulaExpression], _ evaluator: FormulaEvaluator,
                                _ body: (Int, FormulaValue, () throws -> FormulaValue) throws -> T?) throws -> T? {
        guard let items = try evaluator.value(of: arguments[0]).list else { return nil }
        for (index, item) in items.enumerated() {
            let scoped = evaluator.with(["current": item, "index": .number(Double(index))])
            if let result = try body(index, item, { try scoped.value(of: arguments[1]) }) { return result }
        }
        return nil
    }

    private static func listOnly(_ name: String, _ syntax: String, _ summary: String, _ examples: [FormulaExample],
                                 typing: @escaping Typing.Rule, _ body: @escaping @Sendable ([FormulaValue], FormulaEvaluator) throws -> FormulaValue) -> FormulaFunctionInfo {
        FormulaFunctionInfo(name, .lists, syntax, summary, examples, typing: typing, .eager(body))
    }

    /// Порядок для `sort`: числа, тексты, даты, флажки — по возрастанию; пустые и несравнимые — в конце.
    static func ascending(_ a: FormulaValue, _ b: FormulaValue) -> Bool {
        if let order = FormulaValue.order(a, b) { return order < 0 }
        return a != .empty && b == .empty
    }

    static let lists: [FormulaFunctionInfo] = [
        listOnly("at", "at(список, номер)", "Элемент списка по номеру с 0; отрицательный — с конца.",
                 [FormulaExample("at([10, 20, 30], 1)", "20"), FormulaExample("at([10, 20, 30], -1)", "30")],
                 typing: { call in try call.arity(2...2); try call.expect(1, .number); return try Typing.element(of: call) }) { arguments, _ in
            guard let items = arguments.list(0), let number = arguments.number(1) else { return .empty }
            let index = Int(number.rounded(.towardZero)), position = index < 0 ? items.count + index : index
            guard items.indices.contains(position) else { throw FormulaError("Номер \(index) за пределами списка из \(items.count)") }
            return items[position]
        },
        listOnly("first", "first(список)", "Первый элемент списка.", [FormulaExample("first([10, 20, 30])", "10")],
                 typing: { call in try call.arity(1...1); return try Typing.element(of: call) }) { arguments, _ in arguments.list(0)?.first ?? .empty },
        listOnly("last", "last(список)", "Последний элемент списка.", [FormulaExample("last([10, 20, 30])", "30")],
                 typing: { call in try call.arity(1...1); return try Typing.element(of: call) }) { arguments, _ in arguments.list(0)?.last ?? .empty },
        listOnly("slice", "slice(список, от, до?)", "Часть списка с номера «от» до номера «до», не включая его.",
                 [FormulaExample("slice([1, 2, 3, 4], 1, 3)", "2,3"), FormulaExample("slice([1, 2, 3, 4], -2)", "3,4")],
                 typing: { call in
                     try call.arity(2...3)
                     for index in 1..<call.count { try call.expect(index, .number) }
                     return .list(try Typing.element(of: call))
                 }) { arguments, _ in
            guard let items = arguments.list(0) else { return .list([]) }
            let start = clampedIndex(arguments.number(1), count: items.count, default: 0)
            let end = arguments.count > 2 ? clampedIndex(arguments.number(2), count: items.count, default: items.count) : items.count
            return .list(start < end ? Array(items[start..<end]) : [])
        },
        FormulaFunctionInfo("sort", .lists, "sort(список, выражение?)",
                            "Список по возрастанию; с выражением — по его значению для каждого элемента current.",
                            [FormulaExample("sort([3, 1, 2])", "1,2,3"), FormulaExample(#"sort(["bb", "a", "ccc"], length(current))"#, "a,bb,ccc")],
                            typing: { call in
                                try call.arity(1...2)
                                let element = try Typing.element(of: call)
                                if call.count == 2 { _ = try call.type(1, with: ["current": element, "index": .number]) }
                                return .list(element)
                            },
                            .lazy { arguments, evaluator in
                                guard let items = try evaluator.value(of: arguments[0]).list else { return .list([]) }
                                guard arguments.count == 2 else { return .list(items.enumerated().sorted { ascending($0.1, $1.1) || (!ascending($1.1, $0.1) && $0.0 < $1.0) }.map(\.1)) }
                                let keyed = try items.enumerated().map { index, item in
                                    (index, item, try evaluator.with(["current": item, "index": .number(Double(index))]).value(of: arguments[1]))
                                }
                                return .list(keyed.sorted { ascending($0.2, $1.2) || (!ascending($1.2, $0.2) && $0.0 < $1.0) }.map(\.1))
                            }),
        listOnly("reverse", "reverse(список)", "Список в обратном порядке.", [FormulaExample("reverse([1, 2, 3])", "3,2,1")],
                 typing: { call in try call.arity(1...1); return .list(try Typing.element(of: call)) }) { arguments, _ in
            .list((arguments.list(0) ?? []).reversed())
        },
        listOnly("unique", "unique(список)", "Список без повторов, в порядке первого появления.", [FormulaExample("unique([1, 2, 1, 3, 2])", "1,2,3")],
                 typing: { call in try call.arity(1...1); return .list(try Typing.element(of: call)) }) { arguments, _ in
            var seen: Set<FormulaValue> = []
            return .list((arguments.list(0) ?? []).filter { seen.insert($0).inserted })
        },
        listOnly("includes", "includes(список, значение)", "Истина, если в списке есть значение.",
                 [FormulaExample("includes([1, 2, 3], 2)", "true"), FormulaExample(#"includes(["a", "b"], "c")"#, "false")],
                 typing: { call in try call.arity(2...2); _ = try Typing.element(of: call); _ = try call.type(1); return .bool }) { arguments, _ in
            .bool((arguments.list(0) ?? []).contains(arguments[1]))
        },
        FormulaFunctionInfo("find", .lists, "find(список, условие)", "Первый элемент, для которого условие с current истинно.",
                            [FormulaExample("find([1, 2, 3], current > 1)", "2")],
                            typing: { call in try Typing.lambda(call).element },
                            .lazy { arguments, evaluator in try each(arguments, evaluator) { _, item, condition in try condition().isTrue ? item : nil } ?? .empty }),
        FormulaFunctionInfo("findIndex", .lists, "findIndex(список, условие)", "Номер (с 0) первого элемента, для которого условие истинно; нет такого — -1.",
                            [FormulaExample("findIndex([1, 2, 3], current > 1)", "1"), FormulaExample("findIndex([1, 2, 3], current > 5)", "-1")],
                            typing: { call in _ = try Typing.lambda(call); return .number },
                            .lazy { arguments, evaluator in
                                try each(arguments, evaluator) { index, _, condition in try condition().isTrue ? FormulaValue.number(Double(index)) : nil } ?? .number(-1)
                            }),
        FormulaFunctionInfo("filter", .lists, "filter(список, условие)", "Элементы, для которых условие с current истинно.",
                            [FormulaExample("filter([1, 2, 3, 4], current % 2 == 0)", "2,4")],
                            typing: { call in .list(try Typing.lambda(call).element) },
                            .lazy { arguments, evaluator in
                                var kept: [FormulaValue] = []
                                _ = try each(arguments, evaluator) { _, item, condition -> Bool? in
                                    if try condition().isTrue { kept.append(item) }
                                    return nil
                                }
                                return .list(kept)
                            }),
        FormulaFunctionInfo("map", .lists, "map(список, выражение)", "Новый список: выражение для каждого элемента current (index — его номер).",
                            [FormulaExample("map([1, 2, 3], current * 2)", "2,4,6"), FormulaExample("map([5, 5], index)", "0,1")],
                            typing: { call in .list(try Typing.lambda(call).body) },
                            .lazy { arguments, evaluator in
                                var mapped: [FormulaValue] = []
                                _ = try each(arguments, evaluator) { _, _, body -> Bool? in
                                    mapped.append(try body())
                                    return nil
                                }
                                return .list(mapped)
                            }),
        FormulaFunctionInfo("some", .lists, "some(список, условие)", "Истина, если условие истинно хотя бы для одного элемента.",
                            [FormulaExample("some([1, 2, 3], current > 2)", "true")],
                            typing: { call in _ = try Typing.lambda(call); return .bool },
                            .lazy { arguments, evaluator in .bool(try each(arguments, evaluator) { _, _, condition in try condition().isTrue ? true : nil } ?? false) }),
        FormulaFunctionInfo("every", .lists, "every(список, условие)", "Истина, если условие истинно для всех элементов; у пустого списка — истина.",
                            [FormulaExample("every([1, 2, 3], current > 0)", "true"), FormulaExample("every([1, 2, 3], current > 1)", "false")],
                            typing: { call in _ = try Typing.lambda(call); return .bool },
                            .lazy { arguments, evaluator in .bool(try each(arguments, evaluator) { _, _, condition in try condition().isTrue ? nil : false } ?? true) }),
        listOnly("flat", "flat(список)", "Раскрывает вложенные списки на один уровень.", [FormulaExample("flat([[1, 2], [3]])", "1,2,3")],
                 typing: { call in try call.arity(1...1); let element = try Typing.element(of: call); return .list(element.element == .any && element != .any ? .any : element.element) }) { arguments, _ in
            .list((arguments.list(0) ?? []).flatMap { $0.list ?? [$0] })
        },
    ]
}
