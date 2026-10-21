import Foundation

/// Проверка типов и разбор аргументов, общие для разделов функций.
enum Typing {
    typealias Rule = @Sendable (FormulaTypingCall) throws -> FormulaType

    /// Аргументы по порядку, у каждого — допустимые типы; последние `optional` можно не писать.
    static func fixed(_ parameters: [[FormulaType]], optional: Int = 0, _ result: FormulaType) -> Rule {
        { call in
            try call.arity((parameters.count - optional)...parameters.count)
            for index in 0..<call.count {
                let allowed = parameters[index]
                let actual = try call.type(index)
                if !allowed.contains(where: { $0.accepts(actual) }) {
                    throw call.mismatch(index, expected: allowed.map(\.accusative).joined(separator: " или "), got: actual)
                }
            }
            return result
        }
    }

    static func numbers(_ count: Int, optional: Int = 0) -> Rule { fixed(Array(repeating: [.number], count: count), optional: optional, .number) }

    /// Числа и списки чисел в любом количестве (`sum`, `min`, `max`, `mean`, `median`).
    static let numbersOrLists: Rule = { call in
        try call.arity(1...Int.max)
        for index in 0..<call.count {
            let actual = try call.type(index)
            guard FormulaType.number.accepts(actual) || FormulaType.list(.number).accepts(actual) else {
                throw call.mismatch(index, expected: "число или список чисел", got: actual)
            }
        }
        return .number
    }

    /// Первый аргумент — список: тип его элемента.
    static func element(of call: FormulaTypingCall) throws -> FormulaType {
        let list = try call.type(0)
        guard FormulaType.list(.any).accepts(list) else { throw call.mismatch(0, expected: "список", got: list) }
        return list.element
    }

    /// Список и выражение с `current` и `index` (`map`, `filter` …): тип выражения.
    static func lambda(_ call: FormulaTypingCall) throws -> (element: FormulaType, body: FormulaType) {
        try call.arity(2...2)
        let element = try element(of: call)
        return (element, try call.type(1, with: ["current": element, "index": .number]))
    }
}

/// Значения аргументов при вычислении.
extension [FormulaValue] {
    func number(_ index: Int) -> Double? { index < count ? self[index].number : nil }
    func text(_ index: Int) -> String? { index < count ? self[index].text : nil }
    func list(_ index: Int) -> [FormulaValue]? { index < count ? self[index].list : nil }
    func date(_ index: Int) -> FormulaDate? { index < count ? self[index].date : nil }

    /// Числа из чисел и списков чисел; пустые пропускаются.
    var flattenedNumbers: [Double] {
        flatMap { value -> [Double] in
            switch value {
            case .number(let number): [number]
            case .list(let items): items.flattenedNumbers
            default: []
            }
        }
    }
}

/// Номер для `substring`, `slice`, `at`: как в JavaScript — отрицательный считается с конца.
func clampedIndex(_ value: Double?, count: Int, default fallback: Int) -> Int {
    guard let value, value.isFinite else { return fallback }
    let index = Int(value.rounded(.towardZero))
    return index < 0 ? Swift.max(0, count + index) : Swift.min(index, count)
}
