import Foundation
import Testing
@testable import Databases
@testable import NotesCore

/// Итоги колонки и вычисления сводки (contracts/property-types.md, «Итоги колонки и вычисления сводки»).
@Suite("Итоги колонки")
struct CalculationsTests {
    let numbers: [JSONValue?] = [.number(4), .number(1), nil, .number(4), .number(10)]

    @Test("Количество и проценты — у всех типов")
    func counts() {
        let context = TypeFixture.context(.number)
        #expect(Calculations.compute(.countAll, values: numbers, in: context) == .number(5))
        #expect(Calculations.compute(.countValues, values: numbers, in: context) == .number(4))
        #expect(Calculations.compute(.countUnique, values: numbers, in: context) == .number(3))
        #expect(Calculations.compute(.countEmpty, values: numbers, in: context) == .number(1))
        #expect(Calculations.compute(.countNotEmpty, values: numbers, in: context) == .number(4))
        #expect(Calculations.compute(.percentEmpty, values: numbers, in: context) == .number(0.2))
        #expect(Calculations.compute(.percentNotEmpty, values: numbers, in: context) == .number(0.8))
    }

    @Test("Числа: сумма, среднее, медиана, мин, макс, размах; пустые не считаются")
    func numeric() {
        let context = TypeFixture.context(.number)
        #expect(Calculations.compute(.sum, values: numbers, in: context) == .number(19))
        #expect(Calculations.compute(.average, values: numbers, in: context) == .number(4.75))
        #expect(Calculations.compute(.median, values: numbers, in: context) == .number(4))
        #expect(Calculations.compute(.min, values: numbers, in: context) == .number(1))
        #expect(Calculations.compute(.max, values: numbers, in: context) == .number(10))
        #expect(Calculations.compute(.range, values: numbers, in: context) == .number(9))
        #expect(Calculations.compute(.sum, values: [nil], in: context) == nil)
    }

    @Test("Даты: ранняя, поздняя, диапазон в днях")
    func dates() {
        let context = TypeFixture.context(.date)
        let values: [JSONValue?] = [TypeFixture.date("2026-10-21"), TypeFixture.date("2026-10-01"), nil]
        #expect(Calculations.compute(.earliestDate, values: values, in: context) == TypeFixture.date("2026-10-01"))
        #expect(Calculations.compute(.latestDate, values: values, in: context) == TypeFixture.date("2026-10-21"))
        #expect(Calculations.compute(.dateRange, values: values, in: context) == .number(20))
    }

    @Test("Флажок: отмечено, не отмечено, проценты")
    func checkbox() {
        let context = TypeFixture.context(.checkbox)
        let values: [JSONValue?] = [.bool(true), .bool(false), nil, .bool(true)]
        #expect(Calculations.compute(.checked, values: values, in: context) == .number(2))
        #expect(Calculations.compute(.unchecked, values: values, in: context) == .number(2))
        #expect(Calculations.compute(.percentChecked, values: values, in: context) == .number(0.5))
    }

    @Test("Множественный выбор: значения — варианты, а не строки; сводка «как есть» и «уникальные»")
    func listsAndRollup() {
        let context = TypeFixture.context(.multiSelect, options: TypeFixture.options)
        let a = TypeFixture.id(TypeFixture.options[0]), b = TypeFixture.id(TypeFixture.options[1])
        let values: [JSONValue?] = [[a, b], [a], nil]
        #expect(Calculations.compute(.countValues, values: values, in: context) == .number(3))
        #expect(Calculations.compute(.countUnique, values: values, in: context) == .number(2))
        #expect(Calculations.compute(.showOriginal, values: values, in: context) == [a, b, a])
        #expect(Calculations.compute(.showUnique, values: values, in: context) == [a, b])
    }
}
