import AppKit
import NotesCore
import VisualStyle

/// Ячейка таблицы на экране: строка и столбец по порядку.
struct TableCellPosition: Hashable {
    var row: Int
    var column: Int
}

/// Прямоугольник выделенных ячеек.
struct TableCellRange: Equatable {
    var rows: ClosedRange<Int>
    var columns: ClosedRange<Int>

    init(_ cell: TableCellPosition) {
        rows = cell.row...cell.row
        columns = cell.column...cell.column
    }

    init(from start: TableCellPosition, to end: TableCellPosition) {
        rows = min(start.row, end.row)...max(start.row, end.row)
        columns = min(start.column, end.column)...max(start.column, end.column)
    }

    func contains(_ cell: TableCellPosition) -> Bool { rows.contains(cell.row) && columns.contains(cell.column) }

    /// Что выделяет следующий Esc, как у Notion: ячейки → их строки целиком; строки целиком → `nil`, таблица как блок.
    func escaped(columnCount: Int) -> TableCellRange? {
        let fullRows = TableCellRange(from: TableCellPosition(row: rows.lowerBound, column: 0),
                                      to: TableCellPosition(row: rows.upperBound, column: max(0, columnCount - 1)))
        return self == fullRows ? nil : fullRows
    }
}

/// Раскладка таблицы: столбцы по своим ширинам, строки — по самой высокой ячейке (research R3).
@MainActor
struct TableLayout {
    var columnX: [CGFloat] = []
    var columnWidths: [CGFloat] = []
    var rowY: [CGFloat] = []
    var rowHeights: [CGFloat] = []

    var gridSize: NSSize {
        NSSize(width: (columnX.last ?? 0) + (columnWidths.last ?? 0) + Metrics.Table.borderWidth,
               height: (rowY.last ?? 0) + (rowHeights.last ?? 0) + Metrics.Table.borderWidth)
    }

    init() {}

    /// Ячейки текста: высота строки — по самой высокой; `override` — высота текста ячейки, которую сейчас правят.
    init(grid: TableGrid, widths: [CGFloat]? = nil, override: (TableCellPosition, CGFloat)? = nil) {
        var x: CGFloat = 0
        for column in 0..<grid.columnCount {
            let width = widths?[safe: column] ?? CGFloat(grid.width(ofColumn: column))
            columnX.append(x)
            columnWidths.append(width)
            x += width
        }
        var y: CGFloat = 0
        for row in 0..<grid.rowCount {
            var height = Metrics.Table.minimumRowHeight
            for column in 0..<grid.columnCount {
                let position = TableCellPosition(row: row, column: column)
                let textHeight: CGFloat
                if let override, override.0 == position {
                    textHeight = override.1
                } else {
                    let text = Self.text(of: grid, at: position)
                    textHeight = text.length == 0 ? Metrics.Table.lineHeight : Self.height(of: text, width: Self.textWidth(columnWidths[column]))
                }
                height = max(height, textHeight + 2 * Metrics.Table.cellVerticalPadding)
            }
            rowY.append(y)
            rowHeights.append(height.rounded(.up))
            y += height.rounded(.up)
        }
    }

    func cellRect(_ cell: TableCellPosition) -> NSRect {
        NSRect(x: columnX[cell.column], y: rowY[cell.row], width: columnWidths[cell.column], height: rowHeights[cell.row])
    }

    /// Где стоит текст ячейки: внутри полей ячейки, чуть выше — буквы по середине ячейки, как у Notion.
    func textRect(_ cell: TableCellPosition) -> NSRect {
        cellRect(cell).insetBy(dx: Metrics.Table.cellHorizontalPadding, dy: Metrics.Table.cellVerticalPadding)
            .offsetBy(dx: 0, dy: -Metrics.Table.textRaise)
    }

    func cell(at point: NSPoint) -> TableCellPosition? {
        guard let row = rowY.indices.last(where: { rowY[$0] <= point.y }), point.y < rowY[row] + rowHeights[row],
              let column = columnX.indices.last(where: { columnX[$0] <= point.x }), point.x < columnX[column] + columnWidths[column]
        else { return nil }
        return TableCellPosition(row: row, column: column)
    }

    /// Граница справа от столбца под точкой (для протяжки ширины).
    func columnBoundary(near x: CGFloat) -> Int? {
        columnX.indices.first { abs(columnX[$0] + columnWidths[$0] - x) <= Metrics.Table.resizeHandleWidth / 2 }
    }

    static func textWidth(_ columnWidth: CGFloat) -> CGFloat {
        max(1, columnWidth - 2 * Metrics.Table.cellHorizontalPadding)
    }

    /// Текст ячейки, как его рисует таблица и показывает поле правки: шрифт таблицы, оформление в строке.
    static func text(of grid: TableGrid, at cell: TableCellPosition) -> NSAttributedString {
        guard let block = grid.cell(row: cell.row, column: cell.column), !block.text.string.isEmpty else { return NSAttributedString() }
        let text = NSMutableAttributedString(attributedString: PageTextStorageMapper.paragraph(block, withNewline: false))
        if isHeader(cell, in: grid) {
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                text.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
            }
        }
        return text
    }

    static func isHeader(_ cell: TableCellPosition, in grid: TableGrid) -> Bool {
        (grid.hasHeaderRow && cell.row == 0) || (grid.hasHeaderColumn && cell.column == 0)
    }

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            .height.rounded(.up)
    }
}

/// Действия меню строки и столбца (contracts/blocks-and-keys.md, «Таблица»).
enum TableAction: CaseIterable {
    case insertRowAbove, insertRowBelow, insertColumnLeft, insertColumnRight, deleteRow, deleteColumn, toggleHeaderRow, toggleHeaderColumn
}

/// Вид простой таблицы (research R3): ячейки рисует сам, правит одно поле на таблицу — `TableCellEditor` над ячейкой.
/// «+» под таблицей — строка, справа — столбец; ширина столбца — протяжкой правой границы; Esc, как у Notion:
/// выделение ячейки → её строка → таблица выделена как блок.
@MainActor
final class TableView: NSView, PointerOwner {
    let tableId: UUID
    let document: PageDocument
    private weak var host: PageTextView?
    private(set) var tableLayout = TableLayout()
    private(set) var activeCell: TableCellPosition?
    private(set) var selectedCells: TableCellRange?
    /// Выделение клавишей Esc (ячейка, строка) — синяя рамка 2 вокруг, без заливки, как у Notion; мышью — заливка.
    private var isOutlinedSelection = false
    private(set) var editor: TableCellEditor?
    /// Ширины, пока границу тянут: запись — одной правкой при отпускании.
    private var draftWidths: [CGFloat]?
    private var columnDrag: (column: Int, startX: CGFloat, startWidth: CGFloat)?
    private var cellDragStart: TableCellPosition?
    private var isPointerInside = false {
        didSet {
            guard isPointerInside != oldValue else { return }
            addRowButton.isShown = isPointerInside
            addColumnButton.isShown = isPointerInside
        }
    }
    /// «+» под таблицей — строка, справа — столбец; видны, пока мышь над таблицей.
    private let addRowButton = TableAddButton(identifier: "table-add-row", label: "Добавить строку")
    private let addColumnButton = TableAddButton(identifier: "table-add-column", label: "Добавить столбец")

    init(document: PageDocument, tableId: UUID, host: PageTextView) {
        self.document = document
        self.tableId = tableId
        self.host = host
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.table)
        setAccessibilityIdentifier("table")
        for name in [PageDocument.didApplyLocalEdits, PageDocument.didApplyExternalChanges] {
            NotificationCenter.default.addObserver(self, selector: #selector(documentDidChange(_:)), name: name, object: document)
        }
        addRowButton.onPress = { [weak self] in self?.addRow() }
        addColumnButton.onPress = { [weak self] in self?.addColumn() }
        addSubview(addRowButton)
        addSubview(addColumnButton)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var grid: TableGrid? { document.tableGrid(tableId) }

    // MARK: Раскладка

    @objc private func documentDidChange(_ notification: Notification) {
        guard let change = notification.userInfo?[PageDocument.externalChangeKey] as? PageDocument.ExternalChange else { return }
        let rowIds = Set(grid?.rows.map(\.id) ?? [])
        guard change.changedFlowIds.contains(tableId) || !change.changedFlowIds.isDisjoint(with: rowIds)
                || change.changedBlockIds.contains(tableId) || change.removedBlockIds.contains(tableId) else { return }
        reload()
    }

    /// Раскладка заново по документу: ячейка правки остаётся на своей строке и столбце, если они есть.
    func reload() {
        guard let grid else { return }
        var override: (TableCellPosition, CGFloat)?
        if let activeCell, let editor {
            if activeCell.row >= grid.rowCount || activeCell.column >= grid.columnCount {
                deactivateEditor()
            } else {
                override = (activeCell, editor.contentHeight())
            }
        }
        tableLayout = TableLayout(grid: grid, widths: draftWidths, override: override)
        if let selection = selectedCells, selection.rows.upperBound >= grid.rowCount || selection.columns.upperBound >= grid.columnCount {
            selectedCells = nil
        }
        positionEditor()
        addRowButton.frame = addRowRect
        addColumnButton.frame = addColumnRect
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        host?.embeddedViewHeightDidChange(tableId, height: Self.height(of: tableLayout), width: bounds.width)
    }

    /// Высота вида: сетка и место под «+» строки.
    static func height(of layout: TableLayout) -> CGFloat {
        layout.gridSize.height + Metrics.Table.addButtonGap + Metrics.Table.addButtonThickness
    }

    private func positionEditor() {
        guard let editor, let activeCell, activeCell.row < tableLayout.rowHeights.count, activeCell.column < tableLayout.columnWidths.count else { return }
        let padding = editor.textContainer?.lineFragmentPadding ?? 0
        let text = tableLayout.textRect(activeCell)
        let frame = NSRect(x: text.minX - padding, y: text.minY, width: text.width + 2 * padding, height: text.height)
        if editor.frame != frame { editor.frame = frame }
    }

    private var addRowRect: NSRect {
        let grid = tableLayout.gridSize
        return NSRect(x: 0, y: grid.height + Metrics.Table.addButtonGap, width: grid.width, height: Metrics.Table.addButtonThickness)
    }

    private var addColumnRect: NSRect {
        let grid = tableLayout.gridSize
        return NSRect(x: grid.width + Metrics.Table.addButtonGap, y: 0, width: Metrics.Table.addButtonThickness, height: grid.height)
    }

    // MARK: Рисование

    override func draw(_ dirtyRect: NSRect) {
        guard let grid, !tableLayout.columnWidths.isEmpty else { return }
        for row in 0..<grid.rowCount {
            for column in 0..<grid.columnCount {
                let cell = TableCellPosition(row: row, column: column)
                let rect = tableLayout.cellRect(cell)
                guard rect.intersects(dirtyRect) else { continue }
                if TableLayout.isHeader(cell, in: grid) {
                    Palette.tableHeaderBackground.setFill()
                    rect.fill(using: .sourceOver)
                }
                if !isOutlinedSelection, selectedCells?.contains(cell) == true {
                    Palette.blockSelection.setFill()
                    rect.fill(using: .sourceOver)
                }
                guard cell != activeCell || editor == nil else { continue }
                let text = TableLayout.text(of: grid, at: cell)
                guard text.length > 0 else { continue }
                let textRect = tableLayout.textRect(cell)
                text.draw(with: NSRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
        drawBorders(grid)
        if let activeCell, editor != nil {
            strokeSelection(tableLayout.cellRect(activeCell))
        } else if isOutlinedSelection, let selection = selectedCells {
            let first = tableLayout.cellRect(TableCellPosition(row: selection.rows.lowerBound, column: selection.columns.lowerBound))
            let last = tableLayout.cellRect(TableCellPosition(row: selection.rows.upperBound, column: selection.columns.upperBound))
            strokeSelection(first.union(last))
        }
    }

    /// Синяя рамка 2 ячейки правки и выделения клавишей Esc.
    private func strokeSelection(_ rect: NSRect) {
        Palette.tableActiveCell.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 2
        path.stroke()
    }

    private func drawBorders(_ grid: TableGrid) {
        let size = tableLayout.gridSize
        Palette.border.setFill()
        let line = Metrics.Table.borderWidth
        for x in tableLayout.columnX + [size.width - line] {
            NSRect(x: x, y: 0, width: line, height: size.height).fill()
        }
        for y in tableLayout.rowY + [size.height - line] {
            NSRect(x: 0, y: y, width: size.width, height: line).fill()
        }
    }

    // MARK: Ячейка правки

    enum Caret { case start, end }

    /// Поставить поле правки в ячейку и фокус в него.
    func activate(_ cell: TableCellPosition, caret: Caret = .end) {
        guard let grid, let host, cell.row < grid.rowCount, cell.column < grid.columnCount else { return }
        let key = CellKey(row: grid.rows[cell.row].id, column: grid.columns[cell.column].id)
        let editors = host.pageEditor.embeddedViews
        let editor = editors.cellEditors[key] ?? {
            let cellId = grid.cell(row: cell.row, column: cell.column)?.id ?? UUID.timeOrdered()
            let made = TableCellEditor(flow: FlowDocument(document, source: .cell(table: tableId, row: key.row, column: key.column, cellId: cellId)),
                                       host: host, table: self)
            editors.cellEditors[key] = made
            return made
        }()
        editor.table = self
        selectedCells = nil
        if self.editor !== editor { self.editor?.removeFromSuperview() }
        self.editor = editor
        activeCell = cell
        if editor.superview !== self { addSubview(editor) }
        reload()
        window?.makeFirstResponder(editor)
        editor.focus(atEnd: caret == .end)
        needsDisplay = true
    }

    /// Убрать поле правки: текст ячейки снова рисует таблица.
    func deactivateEditor() {
        editor?.commitEdits()
        editor?.removeFromSuperview()
        editor = nil
        activeCell = nil
        needsDisplay = true
    }

    /// Курсор ушёл из таблицы в другой редактор: поле правки — долой.
    func editorDidResign(_ resigned: TableCellEditor) {
        guard resigned === editor else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editor === resigned, let window = self.window,
                  !((window.firstResponder as? NSView)?.isDescendant(of: resigned) ?? false) else { return }
            self.deactivateEditor()
        }
    }

    enum Move { case next, previous, up, down, left, right, enter }

    /// Перейти из ячейки правки в соседнюю: Tab в последней ячейке и Enter в последней строке добавляют строку;
    /// ↑ из первой строки и ↓ из последней — в блоки над и под таблицей.
    func move(_ move: Move) {
        guard let grid, let cell = activeCell else { return }
        var target = cell
        var caret = Caret.end
        switch move {
        case .next:
            if cell.column + 1 < grid.columnCount { target.column += 1 } else { target = TableCellPosition(row: cell.row + 1, column: 0) }
        case .previous:
            if cell.column > 0 { target.column -= 1 } else { target = TableCellPosition(row: cell.row - 1, column: grid.columnCount - 1) }
        case .up: target.row -= 1
        case .down, .enter: target.row += 1
        case .left:
            if cell.column > 0 { target.column -= 1 } else { target = TableCellPosition(row: cell.row - 1, column: grid.columnCount - 1) }
        case .right:
            caret = .start
            if cell.column + 1 < grid.columnCount { target.column += 1 } else { target = TableCellPosition(row: cell.row + 1, column: 0) }
        }
        if target.row < 0 {
            if move == .up || move == .left { leaveTable(upward: true) }
            return
        }
        if target.row >= grid.rowCount {
            switch move {
            case .next, .enter:
                applyChanges(grid.insertingRow(at: grid.rowCount), actionName: "Строка таблицы")
            case .down, .right:
                leaveTable(upward: false)
                return
            default:
                return
            }
        }
        activate(target, caret: caret)
    }

    /// Курсор — в блок над таблицей (в конец) или под ней (в начало).
    private func leaveTable(upward: Bool) {
        guard let host, let index = host.document.index(ofBlock: tableId) else { return }
        let neighbour = index + (upward ? -1 : 1)
        guard host.document.blocks.indices.contains(neighbour) else { return }
        deactivateEditor()
        host.window?.makeFirstResponder(host)
        let start = host.mapper.paragraphStart(ofBlockAt: neighbour)
        host.setSelectedRange(NSRange(location: upward ? start + host.document.blocks[neighbour].pageTextLength : start, length: 0))
    }

    /// Esc в ячейке: ячейка выделена, фокус — у таблицы.
    func escapeFromEditor() {
        guard let cell = activeCell else { return }
        deactivateEditor()
        selectCells(TableCellRange(cell))
        isOutlinedSelection = true
        window?.makeFirstResponder(self)
    }

    // MARK: Выделение ячеек

    func selectCells(_ range: TableCellRange) {
        if editor != nil { deactivateEditor() }
        selectedCells = range
        isOutlinedSelection = false
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            // Ещё Esc — строка ячейки целиком, а у выделенной строки — таблица как блок.
            if let grid, let rows = selectedCells?.escaped(columnCount: grid.columnCount) {
                selectedCells = rows
                isOutlinedSelection = true
                needsDisplay = true
                return
            }
            guard let host, let index = host.document.index(ofBlock: tableId) else { return }
            selectedCells = nil
            needsDisplay = true
            host.window?.makeFirstResponder(host)
            host.selectBlocks(index..<index + 1)
        case #selector(NSResponder.insertNewline(_:)):
            if let selection = selectedCells { activate(TableCellPosition(row: selection.rows.lowerBound, column: selection.columns.lowerBound)) }
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            clearSelectedCells()
        default:
            super.doCommand(by: selector)
        }
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    @objc func copy(_ sender: Any?) {
        copyCells(to: .general)
    }

    /// Текст выделенных ячеек: ячейки через табуляцию, строки — через перевод строки.
    @discardableResult
    func copyCells(to pasteboard: NSPasteboard) -> Bool {
        guard let grid, let selection = selectedCells else { return false }
        let text = selection.rows.map { row in
            selection.columns.map { column in
                grid.text(row: row, column: column).string.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
            }.joined(separator: "\t")
        }.joined(separator: "\n")
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func clearSelectedCells() {
        guard let grid, let selection = selectedCells else { return }
        var changes = BlockChanges()
        for row in selection.rows {
            for column in selection.columns { changes = changes.followed(by: grid.settingText(.empty, row: row, column: column)) }
        }
        applyChanges(changes, actionName: "Очистить ячейки")
    }

    /// Текст с табуляциями и переводами строк — в ячейки от `cell`; таблица растёт под него. `false` — это не ячейки.
    @discardableResult
    func pasteCells(_ string: String, at cell: TableCellPosition) -> Bool {
        let rows = string.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let trimmed = rows.last == "" ? Array(rows.dropLast()) : rows
        guard let grid, string.contains("\t") || trimmed.count > 1 else { return false }
        let texts = trimmed.map { $0.components(separatedBy: "\t").map { InlineText($0) } }
        editor?.commitEdits()
        applyChanges(grid.pasting(texts, at: cell.row, column: cell.column), actionName: "Вставить")
        return true
    }

    // MARK: Строки и столбцы

    func addRow() {
        guard let grid else { return }
        applyChanges(grid.insertingRow(at: grid.rowCount), actionName: "Строка таблицы")
    }

    func addColumn() {
        guard let grid else { return }
        applyChanges(grid.insertingColumn(at: grid.columnCount), actionName: "Столбец таблицы")
    }

    func perform(_ action: TableAction, at cell: TableCellPosition) {
        guard let grid else { return }
        switch action {
        case .insertRowAbove: applyChanges(grid.insertingRow(at: cell.row), actionName: "Строка таблицы")
        case .insertRowBelow: applyChanges(grid.insertingRow(at: cell.row + 1), actionName: "Строка таблицы")
        case .insertColumnLeft: applyChanges(grid.insertingColumn(at: cell.column), actionName: "Столбец таблицы")
        case .insertColumnRight: applyChanges(grid.insertingColumn(at: cell.column + 1), actionName: "Столбец таблицы")
        case .deleteRow: applyChanges(grid.removingRow(at: cell.row), actionName: "Удалить строку")
        case .deleteColumn: applyChanges(grid.removingColumn(at: cell.column), actionName: "Удалить столбец")
        case .toggleHeaderRow: applyChanges(grid.settingHeaders(row: !grid.hasHeaderRow, column: grid.hasHeaderColumn), actionName: "Строка заголовков")
        case .toggleHeaderColumn:
            applyChanges(grid.settingHeaders(row: grid.hasHeaderRow, column: !grid.hasHeaderColumn), actionName: "Столбец заголовков")
        }
    }

    /// Протянуть правую границу столбца до ширины `width`: одна правка.
    func dragColumnBoundary(_ column: Int, toWidth width: CGFloat) {
        guard let grid else { return }
        draftWidths = nil
        applyChanges(grid.settingWidth(Double(width), ofColumn: column), actionName: "Ширина столбца")
    }

    private func applyChanges(_ changes: BlockChanges, actionName: String) {
        guard !changes.isEmpty, let host else { return }
        editor?.commitEdits()
        host.applyStructuralChanges(changes, actionName: actionName)
    }

    // MARK: Мышь

    /// Таблица с «+» столбца: у таблицы во всю ширину кнопка справа за краем вида, как у Notion.
    private var hoverRect: NSRect { bounds.union(addColumnRect) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // AppKit обрезает область по рамке блока: за её краем мышь ведёт pointerMonitor.
        addTrackingArea(NSTrackingArea(rect: hoverRect, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow],
                                       owner: self))
    }

    /// Пока мышь у «+» столбца за краем рамки блока, события вида туда не приходят — их читает монитор окна.
    private var pointerMonitor: Any?

    private func pointerDidMove(toWindowPoint windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        isPointerInside = hoverRect.contains(point)
        if isPointerInside, !visibleRect.contains(point) {
            startPointerMonitor()
        } else {
            stopPointerMonitor()
        }
    }

    private func startPointerMonitor() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            if let self, event.window === self.window { self.pointerDidMove(toWindowPoint: event.locationInWindow) }
            return event
        }
    }

    private func stopPointerMonitor() {
        guard let pointerMonitor else { return }
        NSEvent.removeMonitor(pointerMonitor)
        self.pointerMonitor = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stopPointerMonitor()
            isPointerInside = false
        }
    }

    /// Кнопка «+» столбца за краем вида тоже ловит щелчок.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point) { return hit }
        return addColumnButton.frame.contains(convert(point, from: superview)) ? addColumnButton : nil
    }

    override func mouseEntered(with event: NSEvent) { pointerDidMove(toWindowPoint: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { pointerDidMove(toWindowPoint: event.locationInWindow) }

    override func mouseMoved(with event: NSEvent) { updateCursor(atWindowPoint: event.locationInWindow) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(atWindowPoint: event.locationInWindow) }

    private func updateCursor(atWindowPoint windowPoint: NSPoint) {
        (pointer(atWindowPoint: windowPoint) ?? .arrow).set()
    }

    var pointer: NSCursor { .arrow }

    /// Над линией между столбцами — «↔», над ячейками — I-beam. Текст страницы ставит этот же указатель,
    /// а не свой I-beam поверх «↔»: иначе на каждом сдвиге мыши указатель мигает.
    func pointer(atWindowPoint windowPoint: NSPoint) -> NSCursor? {
        let point = convert(windowPoint, from: nil)
        guard point.x >= 0, point.y >= 0, point.y < tableLayout.gridSize.height else { return nil }
        if tableLayout.columnBoundary(near: point.x) != nil { return .resizeLeftRight }
        return point.x < tableLayout.gridSize.width ? .iBeam : nil
    }

    /// Курсор «↔» на линиях между столбцами закреплён за видом: текстовый вид страницы свой курсор не перебивает.
    override func resetCursorRects() {
        super.resetCursorRects()
        let half = Metrics.Table.resizeHandleWidth / 2
        for column in tableLayout.columnWidths.indices {
            let x = tableLayout.columnX[column] + tableLayout.columnWidths[column]
            addCursorRect(NSRect(x: x - half, y: 0, width: half * 2, height: tableLayout.gridSize.height), cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y < tableLayout.gridSize.height, let column = tableLayout.columnBoundary(near: point.x) {
            columnDrag = (column, point.x, tableLayout.columnWidths[column])
            return
        }
        guard let cell = tableLayout.cell(at: point) else { return }
        if event.clickCount == 1, event.modifierFlags.contains(.shift), let anchor = activeCell ?? selectedCells.map({ TableCellPosition(row: $0.rows.lowerBound, column: $0.columns.lowerBound) }) {
            selectCells(TableCellRange(from: anchor, to: cell))
            window?.makeFirstResponder(self)
            return
        }
        cellDragStart = cell
        activate(cell)
        editor?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let drag = columnDrag {
            var widths = draftWidths ?? tableLayout.columnWidths
            widths[drag.column] = max(CGFloat(TableGrid.minimumColumnWidth), drag.startWidth + point.x - drag.startX)
            draftWidths = widths
            reload()
            return
        }
        guard let start = cellDragStart, let cell = tableLayout.cell(at: point), cell != start else { return }
        selectCells(TableCellRange(from: start, to: cell))
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        cellDragStart = nil
        if let drag = columnDrag, let widths = draftWidths {
            columnDrag = nil
            dragColumnBoundary(drag.column, toWidth: widths[drag.column])
        }
        columnDrag = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let cell = tableLayout.cell(at: convert(event.locationInWindow, from: nil)), let grid else { return nil }
        return TableMenus.menu(for: cell, in: grid, table: self)
    }
}

/// Кнопка «+» таблицы: полоса цвета hoverBackground с плюсом; видна, пока мышь над таблицей.
@MainActor
final class TableAddButton: NSView {
    var onPress: (() -> Void)?
    var isShown = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(isShown ? "виден" : "скрыт")
        }
    }

    init(identifier: String, label: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
        setAccessibilityValue("скрыт")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isShown else { return }
        Palette.hoverBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        Palette.handleIcon.set()
        let plus = NSBezierPath()
        plus.move(to: NSPoint(x: bounds.midX - 5, y: bounds.midY))
        plus.line(to: NSPoint(x: bounds.midX + 5, y: bounds.midY))
        plus.move(to: NSPoint(x: bounds.midX, y: bounds.midY - 5))
        plus.line(to: NSPoint(x: bounds.midX, y: bounds.midY + 5))
        plus.lineWidth = 1.5
        plus.stroke()
    }
}

/// Строка и столбец ячейки по id — ключ поля правки, которое живёт, пока открыта страница.
struct CellKey: Hashable {
    var row: UUID
    var column: UUID
}

/// Фабрика вида таблицы: высота — по тексту ячеек.
@MainActor
final class TableViewFactory: BlockViewFactory {
    func makeView(for block: Block, context: BlockViewContext) -> NSView? {
        guard let textView = context.textView else { return nil }
        let view = TableView(document: textView.document.pageDocument, tableId: block.id, host: textView)
        view.frame.size.width = context.width
        return view
    }

    func height(for block: Block, width: CGFloat) -> CGFloat? { nil }

    func height(for block: Block, width: CGFloat, context: BlockViewContext) -> CGFloat? {
        guard let textView = context.textView else { return nil }
        if let known = textView.embeddedViews.height(of: block.id, width: width) { return known }
        guard let grid = textView.document.pageDocument.tableGrid(block.id) else { return nil }
        return TableView.height(of: TableLayout(grid: grid))
    }
}

extension PageTextView {
    /// Вид таблицы на экране — в этом редакторе или в редакторе колонки.
    func tableView(for tableId: UUID) -> TableView? {
        for editor in pageEditor.editorTree {
            if let view = editor.blockViews.view(for: tableId)?.subviews.first as? TableView { return view }
        }
        return nil
    }
}
