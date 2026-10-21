import AppKit
import Databases
import VisualStyle

/// Группа в сетке (US3): заголовок, её строки (места в сетке) и число строк; у свёрнутой строк в сетке нет.
public struct GridGroupSection: Sendable, Hashable {
    public var key: String
    public var label: GroupLabel
    public var count: Int
    public var rows: Range<Int>
    public var isCollapsed: Bool

    public init(key: String, label: GroupLabel, count: Int, rows: Range<Int>, isCollapsed: Bool) {
        self.key = key
        self.label = label
        self.count = count
        self.rows = rows
        self.isCollapsed = isCollapsed
    }
}

/// Полоса сетки, которая не строка: заголовок группы, «+ Новая строка» (общая и группы), итоги, «+ Новая группа».
public enum GridDecoration: Sendable, Hashable {
    case groupHeader(Int)
    case groupNewRow(Int)
    case groupTotals(Int)
    case newRow
    case totals
    case newGroup
}

/// Раскладка сетки по вертикали (US3): строки разной высоты (перенос текста) и полосы групп между ними. Строки — места
/// 0..<n по порядку; места и высоты — массивы, строка под точкой ищется делением пополам.
public struct GridLayout: Sendable {
    public static let groupHeaderHeight: CGFloat = 42
    public static let groupGap: CGFloat = 12
    public static let totalsHeight: CGFloat = 33

    public private(set) var rowTops: [CGFloat] = []
    public private(set) var rowHeights: [CGFloat] = []
    public private(set) var decorations: [(item: GridDecoration, top: CGFloat, height: CGFloat)] = []
    /// Низ последних строк (без итогов и кнопок) — для липкой шапки.
    public private(set) var rowsBottom: CGFloat = Metrics.DatabaseGrid.headerHeight
    public private(set) var height: CGFloat = Metrics.DatabaseGrid.headerHeight

    public init() {}

    /// `rowHeight` — высота строки по месту (известная или обычная); `groups` — показанные группы по порядку.
    public init(rowCount: Int, rowHeight: (Int) -> CGFloat, groups: [GridGroupSection]?, showsNewRow: Bool, hasTotals: Bool, showsNewGroup: Bool) {
        var y = Metrics.DatabaseGrid.headerHeight
        rowTops.reserveCapacity(rowCount)
        rowHeights.reserveCapacity(rowCount)
        func addRows(_ range: Range<Int>) {
            for index in range where index < rowCount {
                let height = rowHeight(index)
                rowTops.append(y)
                rowHeights.append(height)
                y += height
            }
        }
        func add(_ item: GridDecoration, _ height: CGFloat) {
            decorations.append((item, y, height))
            y += height
        }
        if let groups {
            for (index, group) in groups.enumerated() {
                if index > 0 { y += Self.groupGap }
                add(.groupHeader(index), Self.groupHeaderHeight)
                guard !group.isCollapsed else { continue }
                addRows(group.rows)
                rowsBottom = y
                if showsNewRow { add(.groupNewRow(index), Metrics.DatabaseGrid.rowHeight) }
                if hasTotals { add(.groupTotals(index), Self.totalsHeight) }
            }
            // Строки вне показанных групп (их нет в сетке, но на всякий случай) — в конце.
            if rowTops.count < rowCount { addRows(rowTops.count..<rowCount) }
            if showsNewGroup {
                y += Self.groupGap
                add(.newGroup, Metrics.DatabaseGrid.rowHeight)
            }
        } else {
            addRows(0..<rowCount)
            rowsBottom = y
            if showsNewRow { add(.newRow, Metrics.DatabaseGrid.rowHeight) }
            if hasTotals { add(.totals, Self.totalsHeight) }
        }
        rowsBottom = max(rowsBottom, rowTops.last.map { $0 + rowHeights.last! } ?? rowsBottom)
        height = y
    }

    public var rowCount: Int { rowTops.count }

    public func rowRect(_ index: Int, width: CGFloat) -> NSRect {
        guard index >= 0 else { return NSRect(x: 0, y: Metrics.DatabaseGrid.headerHeight, width: width, height: Metrics.DatabaseGrid.rowHeight) }
        guard index < rowTops.count else {
            return NSRect(x: 0, y: rowsBottom + CGFloat(index - rowTops.count) * Metrics.DatabaseGrid.rowHeight, width: width,
                          height: Metrics.DatabaseGrid.rowHeight)
        }
        return NSRect(x: 0, y: rowTops[index], width: width, height: rowHeights[index])
    }

    /// Первая строка, чей низ ниже `y`.
    private func firstRow(below y: CGFloat) -> Int {
        var low = 0, high = rowTops.count
        while low < high {
            let middle = (low + high) / 2
            if rowTops[middle] + rowHeights[middle] <= y { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Строки, задевающие полосу `minY..<maxY`.
    public func rows(from minY: CGFloat, to maxY: CGFloat) -> Range<Int> {
        let first = firstRow(below: minY)
        var last = first
        while last < rowTops.count, rowTops[last] < maxY { last += 1 }
        return first..<last
    }

    /// Строка под `y`; между строками (заголовок, кнопка) — `nil`.
    public func row(at y: CGFloat) -> Int? {
        let index = firstRow(below: y)
        guard index < rowTops.count, rowTops[index] <= y else { return nil }
        return index
    }

    /// Ближайшая строка (протяжка за край таблицы и между группами).
    public func nearestRow(to y: CGFloat) -> Int { max(0, min(firstRow(below: y), rowTops.count - 1)) }

    /// Место вставки при перетаскивании строки: перед строкой, чья середина ниже `y`.
    public func insertionIndex(at y: CGFloat) -> Int {
        var index = firstRow(below: y)
        if index < rowTops.count, y > rowTops[index] + rowHeights[index] / 2 { index += 1 }
        return min(index, rowTops.count)
    }

    public func decoration(at y: CGFloat) -> (item: GridDecoration, top: CGFloat, height: CGFloat)? {
        decorations.first { y >= $0.top && y < $0.top + $0.height }
    }

    public func rect(of item: GridDecoration, width: CGFloat) -> NSRect? {
        decorations.first { $0.item == item }.map { NSRect(x: 0, y: $0.top, width: width, height: $0.height) }
    }
}
