import Foundation

/// Ячейка сетки: строка вида и видимая колонка, с нуля.
public struct CellPosition: Sendable, Hashable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }
}

/// Размер таблицы вида: строк и видимых колонок.
public struct GridBounds: Sendable, Hashable {
    public var rows: Int
    public var columns: Int

    public init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
    }
}

/// Шаг по ячейкам: стрелки, Tab и ⇧Tab.
public enum CellMove: Sendable, Hashable {
    case up, down, left, right
    /// Вправо; с последней колонки — в начало следующей строки.
    case tab
    /// Влево; с первой колонки — в конец предыдущей строки.
    case backtab
}

/// Выделенные ячейки — прямоугольник от опоры (где начали) до фокуса (куда дошли ⇧-стрелками, ⇧-щелчком или протяжкой).
public struct CellSelection: Sendable, Hashable {
    public var anchor: CellPosition
    public var focus: CellPosition

    public init(_ position: CellPosition) {
        anchor = position
        focus = position
    }

    /// ⌘A: все ячейки вида; пустой таблице выделять нечего.
    public static func all(in bounds: GridBounds) -> CellSelection? {
        guard bounds.rows > 0, bounds.columns > 0 else { return nil }
        var selection = CellSelection(CellPosition(row: 0, column: 0))
        selection.focus = CellPosition(row: bounds.rows - 1, column: bounds.columns - 1)
        return selection
    }

    public var rows: ClosedRange<Int> { min(anchor.row, focus.row)...max(anchor.row, focus.row) }
    public var columns: ClosedRange<Int> { min(anchor.column, focus.column)...max(anchor.column, focus.column) }
    public var topLeft: CellPosition { CellPosition(row: rows.lowerBound, column: columns.lowerBound) }
    public var isSingleCell: Bool { anchor == focus }

    public func contains(_ position: CellPosition) -> Bool { rows.contains(position.row) && columns.contains(position.column) }

    /// Протяжка и ⇧-щелчок: фокус — сюда, опора на месте.
    public mutating func extend(to position: CellPosition) {
        focus = position
    }

    /// Шаг от фокуса: с ⇧ — прямоугольник растёт, без — одна ячейка.
    public func moved(_ move: CellMove, extending: Bool, in bounds: GridBounds) -> CellSelection {
        guard bounds.rows > 0, bounds.columns > 0 else { return self }
        var target = focus
        switch move {
        case .up: target.row -= 1
        case .down: target.row += 1
        case .left: target.column -= 1
        case .right: target.column += 1
        case .tab:
            if target.column < bounds.columns - 1 { target.column += 1 } else if target.row < bounds.rows - 1 { target = CellPosition(row: target.row + 1, column: 0) }
        case .backtab:
            if target.column > 0 { target.column -= 1 } else if target.row > 0 { target = CellPosition(row: target.row - 1, column: bounds.columns - 1) }
        }
        target.row = min(max(target.row, 0), bounds.rows - 1)
        target.column = min(max(target.column, 0), bounds.columns - 1)
        guard extending else { return CellSelection(target) }
        var selection = self
        selection.focus = target
        return selection
    }
}
