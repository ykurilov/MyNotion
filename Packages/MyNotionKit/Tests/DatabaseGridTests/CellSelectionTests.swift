import Foundation
import Testing
@testable import DatabaseGrid

/// Выделение ячеек и клавиши (T032, contracts/database-ui.md, «Ячейки и клавиши»).
@Suite("Сетка: выделение и клавиши")
struct CellSelectionTests {
    let bounds = GridBounds(rows: 5, columns: 4)

    func at(_ row: Int, _ column: Int) -> CellPosition { CellPosition(row: row, column: column) }

    @Test("Стрелки ходят по ячейкам и не выходят за край")
    func arrows() {
        var selection = CellSelection(at(0, 0))
        selection = selection.moved(.down, extending: false, in: bounds)
        selection = selection.moved(.right, extending: false, in: bounds)
        #expect(selection == CellSelection(at(1, 1)))
        #expect(CellSelection(at(0, 0)).moved(.up, extending: false, in: bounds) == CellSelection(at(0, 0)))
        #expect(CellSelection(at(4, 3)).moved(.right, extending: false, in: bounds) == CellSelection(at(4, 3)))
    }

    @Test("Tab — вправо и на следующую строку, ⇧Tab — обратно")
    func tab() {
        #expect(CellSelection(at(0, 2)).moved(.tab, extending: false, in: bounds) == CellSelection(at(0, 3)))
        #expect(CellSelection(at(0, 3)).moved(.tab, extending: false, in: bounds) == CellSelection(at(1, 0)))
        #expect(CellSelection(at(1, 0)).moved(.backtab, extending: false, in: bounds) == CellSelection(at(0, 3)))
        #expect(CellSelection(at(4, 3)).moved(.tab, extending: false, in: bounds) == CellSelection(at(4, 3)))
    }

    @Test("⇧-стрелки и протяжка — прямоугольник от опоры; стрелка без ⇧ схлопывает к фокусу")
    func rectangle() {
        var selection = CellSelection(at(1, 1))
        selection = selection.moved(.down, extending: true, in: bounds).moved(.down, extending: true, in: bounds)
        selection = selection.moved(.right, extending: true, in: bounds)
        #expect(selection.rows == 1...3 && selection.columns == 1...2)
        #expect(selection.contains(at(2, 2)) && !selection.contains(at(0, 1)))
        selection = selection.moved(.up, extending: true, in: bounds).moved(.up, extending: true, in: bounds)
            .moved(.up, extending: true, in: bounds)
        #expect(selection.rows == 0...1, "через опору — в другую сторону")

        var dragged = CellSelection(at(3, 3))
        dragged.extend(to: at(1, 0))
        #expect(dragged.rows == 1...3 && dragged.columns == 0...3)
        #expect(dragged.topLeft == at(1, 0))
        #expect(dragged.moved(.down, extending: false, in: bounds) == CellSelection(at(2, 0)))
        #expect(!dragged.isSingleCell && CellSelection(at(0, 0)).isSingleCell)
    }

    @Test("⌘A — все ячейки вида; у пустой таблицы выделять нечего")
    func selectAll() {
        let all = CellSelection.all(in: bounds)
        #expect(all?.rows == 0...4 && all?.columns == 0...3)
        #expect(CellSelection.all(in: GridBounds(rows: 0, columns: 3)) == nil)
    }

    @Test("Клавиши выбранной ячейки: Enter — правка, буква — правка с заменой, Esc — строка, ⌫ — стереть, ⌘C/⌘X/⌘V/⌘A")
    func keysOnSelectedCell() {
        func command(_ key: CellKey, _ modifiers: CellModifiers = [], _ characters: String? = nil) -> CellCommand {
            CellKeyboard.command(for: key, modifiers: modifiers, characters: characters, isEditing: false)
        }
        #expect(command(.enter) == .beginEditing(replacingWith: nil))
        #expect(command(.character, [], "ж") == .beginEditing(replacingWith: "ж"))
        #expect(command(.character, [.shift], "Ж") == .beginEditing(replacingWith: "Ж"))
        #expect(command(.escape) == .selectRow)
        #expect(command(.delete) == .erase)
        #expect(command(.forwardDelete) == .erase)
        #expect(command(.arrow(.left), [.shift]) == .move(.left, extending: true))
        #expect(command(.tab) == .move(.tab, extending: false))
        #expect(command(.tab, [.shift]) == .move(.backtab, extending: false))
        #expect(command(.character, [.command], "c") == .copy)
        #expect(command(.character, [.command], "x") == .cut)
        #expect(command(.character, [.command], "v") == .paste)
        #expect(command(.character, [.command], "a") == .selectAll)
        #expect(command(.enter, [.shift, .command]) == .openInNewTab)
        #expect(command(.character, [.command], "d") == .duplicateRows)
        #expect(command(.character, [.command], "z") == .none, "⌘Z — меню «Правка», не сетка")
    }

    @Test("Клавиши в правке: Enter — готово и ячейка ниже, Tab — готово и вправо, Esc — выход, ячейка выбрана")
    func keysWhileEditing() {
        func command(_ key: CellKey, _ modifiers: CellModifiers = []) -> CellCommand {
            CellKeyboard.command(for: key, modifiers: modifiers, characters: nil, isEditing: true)
        }
        #expect(command(.enter) == .commit(then: .down))
        #expect(command(.tab) == .commit(then: .tab))
        #expect(command(.tab, [.shift]) == .commit(then: .backtab))
        #expect(command(.escape) == .commit(then: nil))
        #expect(command(.arrow(.left)) == .none, "стрелки в правке — по тексту")
        #expect(command(.enter, [.shift]) == .none, "⇧Enter — перевод строки в тексте")
    }
}
