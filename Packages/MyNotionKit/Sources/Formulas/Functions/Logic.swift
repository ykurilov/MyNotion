extension FormulaFunctions {
    static let logic: [FormulaFunctionInfo] = [
        FormulaFunctionInfo("if", .general, "if(условие, еслиДа, еслиНет)",
                            "Если условие истинно — второе значение, иначе третье.",
                            [FormulaExample("if(true, 1, 2)", "1"), FormulaExample("if(false, 1, 2)", "2")],
                            typing: { call in
                                try call.arity(3...3)
                                _ = try call.type(0)
                                return try call.type(1).merged(with: try call.type(2))
                            },
                            .lazy { arguments, evaluator in
                                try evaluator.value(of: arguments[0]).isTrue ? try evaluator.value(of: arguments[1]) : try evaluator.value(of: arguments[2])
                            }),
        FormulaFunctionInfo("ifs", .general, "ifs(условие, значение, условие2, значение2, …, иначе)",
                            "Значение при первом истинном условии; если ни одно не истинно — последнее. Замена вложенным if().",
                            [FormulaExample("ifs(true, 1, true, 2, 3)", "1"), FormulaExample("ifs(false, 1, false, 2, 3)", "3")],
                            typing: { call in
                                try call.arity(3...Int.max)
                                guard call.count % 2 == 1 else {
                                    throw FormulaError("Функция ifs ждёт пары «условие, значение» и значение «иначе» в конце", at: call.range)
                                }
                                var result = try call.type(call.count - 1)
                                for index in stride(from: 0, to: call.count - 1, by: 2) {
                                    _ = try call.type(index)
                                    result = result.merged(with: try call.type(index + 1))
                                }
                                return result
                            },
                            .lazy { arguments, evaluator in
                                for index in stride(from: 0, to: arguments.count - 1, by: 2) where try evaluator.value(of: arguments[index]).isTrue {
                                    return try evaluator.value(of: arguments[index + 1])
                                }
                                return try evaluator.value(of: arguments[arguments.count - 1])
                            }),
        FormulaFunctionInfo("and", .general, "and(условие, условие, …)", "Истина, если истинны все условия. То же — and и &&.",
                            [FormulaExample("and(true, false)", "false"), FormulaExample("and(true, true)", "true")],
                            typing: { call in try call.arity(2...Int.max); for i in 0..<call.count { _ = try call.type(i) }; return .bool },
                            .eager { arguments, _ in .bool(arguments.allSatisfy(\.isTrue)) }),
        FormulaFunctionInfo("or", .general, "or(условие, условие, …)", "Истина, если истинно хотя бы одно условие. То же — or и ||.",
                            [FormulaExample("or(true, false)", "true"), FormulaExample("or(false, false)", "false")],
                            typing: { call in try call.arity(2...Int.max); for i in 0..<call.count { _ = try call.type(i) }; return .bool },
                            .eager { arguments, _ in .bool(arguments.contains(where: \.isTrue)) }),
        FormulaFunctionInfo("not", .general, "not(условие)", "Обратное значение условия. То же — not и !.",
                            [FormulaExample("not(true)", "false"), FormulaExample(#"not empty("")"#, "false")],
                            typing: { call in try call.arity(1...1); _ = try call.type(0); return .bool },
                            .eager { arguments, _ in .bool(!arguments[0].isTrue) }),
        FormulaFunctionInfo("empty", .general, "empty(значение)",
                            "Истина, если значение пустое: пусто, 0, \"\", [] и снятый флажок.",
                            [FormulaExample("empty(0)", "true"), FormulaExample("empty([])", "true"), FormulaExample(#"empty("")"#, "true"), FormulaExample("empty([1])", "false")],
                            typing: { call in try call.arity(0...1); if call.count == 1 { _ = try call.type(0) }; return .bool },
                            .eager { arguments, _ in .bool(!(arguments.first?.isTrue ?? false)) }),
        FormulaFunctionInfo("equal", .general, "equal(значение, значение)", "Истина, если значения равны. То же — ==.",
                            [FormulaExample("equal(1, 1)", "true"), FormulaExample(#""a" == "b""#, "false")],
                            typing: { call in try call.arity(2...2); _ = try call.type(0); _ = try call.type(1); return .bool },
                            .eager { arguments, _ in .bool(arguments[0] == arguments[1]) }),
        FormulaFunctionInfo("unequal", .general, "unequal(значение, значение)", "Истина, если значения различаются. То же — !=.",
                            [FormulaExample("unequal(1, 2)", "true"), FormulaExample(#""a" != "a""#, "false")],
                            typing: { call in try call.arity(2...2); _ = try call.type(0); _ = try call.type(1); return .bool },
                            .eager { arguments, _ in .bool(arguments[0] != arguments[1]) }),
    ]
}
