import AppKit
import CoreText
import Databases
import NotesCore
import VisualStyle

/// Документ сетки: строки под шапкой, каждая рисуется в своей полосе; ниже — «+ Новая строка». Принимает клавиши
/// выбранных ячеек, щелчки, протяжку и правый щелчок.
@MainActor
final class GridDocumentView: NSView, NSMenuItemValidation {
    let content: GridContent
    let text = GridTextRenderer()
    weak var grid: DatabaseGridView?
    /// Строка под мышью: «ОТКРЫТЬ» и ручки.
    private(set) var hoverRow: Int? {
        didSet {
            guard hoverRow != oldValue else { return }
            if let oldValue { setNeedsDisplay(rows: oldValue..<oldValue + 1) }
            if let hoverRow { setNeedsDisplay(rows: hoverRow..<hoverRow + 1) }
            grid?.hoverControls.update()
        }
    }
    /// Ячейка с кнопкой при наведении (ссылка, email, телефон).
    private var hoverCell: CellPosition?
    let openButton = GridOpenButton()
    let linkButton = GridLinkButton()
    /// Место вставки при перетаскивании строки (линия над строкой).
    var dropRow: Int? { didSet { if dropRow != oldValue { needsDisplay = true } } }
    private var dragAnchor: CellPosition?
    private var mouseDownPosition: CellPosition?
    private var didDrag = false

    init(content: GridContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        openButton.isHidden = true
        openButton.target = self
        openButton.action = #selector(openHoveredRow)
        addSubview(openButton)
        linkButton.isHidden = true
        linkButton.target = self
        linkButton.action = #selector(openHoveredLink)
        addSubview(linkButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { grid?.controller != nil }

    var tableWidth: CGFloat { content.columns.reduce(0) { $0 + $1.width } }
    var showsNewRow: Bool { grid?.showsNewRowButton ?? false }
    var rowsHeight: CGFloat { Metrics.DatabaseGrid.headerHeight + CGFloat(content.rowCount) * Metrics.DatabaseGrid.rowHeight }
    var tableHeight: CGFloat { rowsHeight + (showsNewRow ? Metrics.DatabaseGrid.rowHeight : 0) }
    var newRowRect: NSRect { NSRect(x: 0, y: rowsHeight, width: max(tableWidth, 120), height: Metrics.DatabaseGrid.rowHeight) }

    func updateSize(minimumWidth: CGFloat) {
        let extra = showsNewRow ? GridHeaderView.trailingButtonsWidth + 140 : 0
        let size = NSSize(width: max(tableWidth + 1 + extra, minimumWidth), height: tableHeight + 1)
        // Слой рисуется по запросу: выросшая часть (новые колонки, строки) сама не дорисуется.
        if frame.size != size {
            setFrameSize(size)
            needsDisplay = true
        }
    }

    func rows(in rect: NSRect) -> Range<Int> {
        let rowHeight = Metrics.DatabaseGrid.rowHeight
        let top = max(0, Int(((rect.minY - Metrics.DatabaseGrid.headerHeight) / rowHeight).rounded(.down)))
        let bottom = min(content.rowCount, Int(((rect.maxY - Metrics.DatabaseGrid.headerHeight) / rowHeight).rounded(.up)))
        return top < bottom ? top..<bottom : top..<top
    }

    func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 0, y: Metrics.DatabaseGrid.headerHeight + CGFloat(index) * Metrics.DatabaseGrid.rowHeight, width: bounds.width,
               height: Metrics.DatabaseGrid.rowHeight)
    }

    func cellRect(row: Int, column: Int) -> NSRect {
        let x = content.columns.prefix(column).reduce(0) { $0 + $1.width }
        var rect = rowRect(row)
        rect.origin.x = x
        rect.size.width = content.columns.indices.contains(column) ? content.columns[column].width : 0
        return rect
    }

    /// Ячейка под точкой документа; вне строк или колонок — `nil`.
    func position(at point: NSPoint) -> CellPosition? {
        guard point.y >= Metrics.DatabaseGrid.headerHeight, point.y < rowsHeight else { return nil }
        let row = Int((point.y - Metrics.DatabaseGrid.headerHeight) / Metrics.DatabaseGrid.rowHeight)
        var x: CGFloat = 0
        for (index, column) in content.columns.enumerated() {
            if point.x >= x, point.x < x + column.width { return CellPosition(row: row, column: index) }
            x += column.width
        }
        return nil
    }

    /// Ближайшая ячейка (протяжка за край таблицы).
    func nearestPosition(to point: NSPoint) -> CellPosition? {
        guard content.rowCount > 0, !content.columns.isEmpty else { return nil }
        let clamped = NSPoint(x: min(max(point.x, 0), tableWidth - 1),
                              y: min(max(point.y, Metrics.DatabaseGrid.headerHeight), rowsHeight - 1))
        return position(at: clamped)
    }

    func setNeedsDisplay(rows: Range<Int>) {
        guard !rows.isEmpty else { return }
        let rect = rowRect(rows.lowerBound).union(rowRect(rows.upperBound - 1))
        setNeedsDisplay(rect.insetBy(dx: 0, dy: -2))
    }

    func selectionDidChange(from old: CellSelection?) {
        for selection in [old, grid?.selection].compactMap({ $0 }) {
            setNeedsDisplay(rows: selection.rows.lowerBound..<min(selection.rows.upperBound + 1, content.rowCount))
        }
    }

    // MARK: Рисование

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rows = rows(in: dirtyRect)
        let lineColor = Palette.databaseGridLine.cgColor
        let lineWidth = Metrics.DatabaseGrid.lineWidth
        let tableWidth = tableWidth
        var columnRanges: [(index: Int, minX: CGFloat, width: CGFloat)] = []
        var x: CGFloat = 0
        for (index, column) in content.columns.enumerated() {
            if x + column.width >= dirtyRect.minX, x <= dirtyRect.maxX { columnRanges.append((index, x, column.width)) }
            x += column.width
        }
        let selectedRows = grid?.selectedRows ?? []
        for index in rows {
            let rect = rowRect(index)
            if selectedRows.contains(index) {
                context.setFillColor(Palette.blockSelection.cgColor)
                context.fill(CGRect(x: 0, y: rect.minY, width: tableWidth, height: rect.height))
            }
            context.setFillColor(lineColor)
            context.fill(CGRect(x: 0, y: rect.maxY - lineWidth, width: tableWidth, height: lineWidth))
            guard let row = content.row(at: index) else { continue }
            for (column, minX, width) in columnRanges {
                let cell = CGRect(x: minX, y: rect.minY, width: width, height: rect.height - lineWidth)
                context.setFillColor(lineColor)
                if column > 0 { context.fill(CGRect(x: minX, y: rect.minY, width: lineWidth, height: rect.height)) }
                if grid?.editor?.position == CellPosition(row: index, column: column) { continue }
                let isTitle = content.columns[column].property.kind == .title
                draw(row.cells[column], in: cell, column: content.columns[column], icon: isTitle ? .some(row.icon) : nil,
                     reservesOpen: isTitle && hoverRow == index, context: context)
            }
        }
        if tableWidth >= dirtyRect.minX, tableWidth <= dirtyRect.maxX, let first = rows.first, let last = rows.last {
            context.setFillColor(lineColor)
            context.fill(CGRect(x: tableWidth, y: rowRect(first).minY, width: lineWidth, height: rowRect(last).maxY - rowRect(first).minY))
        }
        if showsNewRow, newRowRect.intersects(dirtyRect) { drawNewRow(context: context) }
        drawSelection(context: context, dirtyRect: dirtyRect)
        if let dropRow {
            let y = dropRow < content.rowCount ? rowRect(dropRow).minY : rowsHeight
            context.setFillColor(Palette.dropIndicator.cgColor)
            context.fill(CGRect(x: 0, y: y - 1.5, width: tableWidth, height: 3))
        }
    }

    /// «+ Новая строка» серым под строками.
    private func drawNewRow(context: CGContext) {
        let rect = newRowRect
        if hoverNewRow {
            context.setFillColor(Palette.hoverBackground.cgColor)
            context.fill(rect)
        }
        let symbol = GridSymbols.image("plus", size: 13, color: Palette.textSecondary)
        let iconRect = CGRect(x: rect.minX + Metrics.DatabaseGrid.cellHorizontalPadding, y: rect.midY - 8, width: 16, height: 16)
        symbol.draw(in: iconRect)
        text.draw(GridStrings.newRow, in: CGRect(x: iconRect.maxX + 6, y: rect.minY, width: rect.width - iconRect.maxX - 6, height: rect.height),
                  color: Palette.textSecondary, alignment: .left, context: context)
    }

    /// Рамка выбранных ячеек: синяя, ≈ 1,5; несколько ячеек — ещё и заливка.
    private func drawSelection(context: CGContext, dirtyRect: NSRect) {
        guard let selection = grid?.selection, grid?.editor == nil || !selection.isSingleCell else { return }
        let first = cellRect(row: selection.rows.lowerBound, column: selection.columns.lowerBound)
        let last = cellRect(row: selection.rows.upperBound, column: selection.columns.upperBound)
        let rect = first.union(last).insetBy(dx: 0.75, dy: 0.75)
        guard rect.intersects(dirtyRect.insetBy(dx: -2, dy: -2)) else { return }
        if !selection.isSingleCell {
            context.setFillColor(Palette.blockSelection.cgColor)
            context.fill(rect)
        }
        context.setStrokeColor(Palette.focusRing.cgColor)
        context.setLineWidth(1.5)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil))
        context.strokePath()
    }

    /// `icon` — у колонки «Название»: `.some(nil)` — значок листа, `.some(эмодзи)` — эмодзи строки.
    private func draw(_ cell: CellPresentation, in rect: CGRect, column: GridColumn, icon: String??, reservesOpen: Bool, context: CGContext) {
        let padding = Metrics.DatabaseGrid.cellHorizontalPadding
        var inner = rect.insetBy(dx: padding, dy: 0)
        if let icon {
            let iconRect = CGRect(x: inner.minX, y: rect.midY - 9, width: 18, height: 18)
            if let emoji = icon {
                text.draw(emoji, in: iconRect.insetBy(dx: -1, dy: 0), color: Palette.textPrimary, alignment: .left, context: context)
            } else {
                GridSymbols.documentGlyph.draw(in: iconRect.insetBy(dx: 1, dy: 1))
            }
            inner.origin.x += 24
            inner.size.width -= 24
            if reservesOpen { inner.size.width -= GridOpenButton.size.width + 6 }
        }
        switch cell {
        case .empty: break
        case .text(let string):
            text.draw(string, in: inner, color: Palette.textPrimary, alignment: column.alignsRight ? .right : .left,
                      weight: column.property.kind == .title ? .medium : .regular, context: context)
        case .checkbox(let checked):
            let size = Metrics.DatabaseGrid.checkboxSize
            let box = CGRect(x: inner.minX, y: rect.midY - size / 2, width: size, height: size)
            let path = CGPath(roundedRect: box, cornerWidth: Metrics.DatabaseGrid.checkboxCornerRadius,
                              cornerHeight: Metrics.DatabaseGrid.checkboxCornerRadius, transform: nil)
            context.addPath(path)
            if checked {
                context.setFillColor(Palette.checkboxChecked.cgColor)
                context.fillPath()
                context.setStrokeColor(Palette.checkboxCheckmark.cgColor)
                context.setLineWidth(1.6)
                context.move(to: CGPoint(x: box.minX + 3.5, y: box.midY))
                context.addLine(to: CGPoint(x: box.minX + 6.8, y: box.maxY - 4))
                context.addLine(to: CGPoint(x: box.maxX - 3.2, y: box.minY + 4))
                context.strokePath()
            } else {
                context.setStrokeColor(Palette.textSecondary.cgColor)
                context.setLineWidth(1.2)
                context.strokePath()
            }
        case .chips(let chips):
            var chipX = inner.minX
            let height = Metrics.DatabaseGrid.chipHeight
            for chip in chips {
                guard chipX < inner.maxX - 12 else { break }
                // Статус, картинка файла — свой вид плашки (US2, `Cells/StatusCell.swift`, `Cells/FilesCell.swift`).
                if let width = CellChipStyles.draw(chip, at: CGPoint(x: chipX, y: rect.midY), maxX: inner.maxX, store: content.store) {
                    chipX += width + Metrics.DatabaseGrid.chipSpacing
                    continue
                }
                let textWidth = min(text.width(chip.title, size: Metrics.DatabaseGrid.chipFontSize), inner.maxX - chipX - 2 * Metrics.DatabaseGrid.chipHorizontalPadding)
                let chipRect = CGRect(x: chipX, y: rect.midY - height / 2, width: textWidth + 2 * Metrics.DatabaseGrid.chipHorizontalPadding, height: height)
                context.addPath(CGPath(roundedRect: chipRect, cornerWidth: Metrics.DatabaseGrid.chipCornerRadius,
                                       cornerHeight: Metrics.DatabaseGrid.chipCornerRadius, transform: nil))
                context.setFillColor(Palette.optionChipBackground(chip.color.rawValue).cgColor)
                context.fillPath()
                text.draw(chip.title, in: chipRect.insetBy(dx: Metrics.DatabaseGrid.chipHorizontalPadding, dy: 0), color: Palette.optionChipText,
                          alignment: .left, context: context)
                chipX = chipRect.maxX + Metrics.DatabaseGrid.chipSpacing
            }
        case .meter(let meter):
            NumberMeterDrawing.draw(meter, in: inner, cellRect: rect, text: text, context: context)
        }
    }

    // MARK: Наведение

    private var trackingArea: NSTrackingArea?
    private var hoverNewRow = false { didSet { if hoverNewRow != oldValue { setNeedsDisplay(newRowRect) } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        // Мышь ушла на ручки строки слева — строка остаётся под наведением.
        if let window, grid?.hoverControls.contains(screenPoint: NSEvent.mouseLocation, in: window) == true { return }
        hover(at: nil)
    }

    func hover(at point: NSPoint?) {
        guard grid?.controller != nil, let point else {
            hoverRow = nil
            hoverNewRow = false
            placeButtons()
            return
        }
        hoverNewRow = showsNewRow && newRowRect.contains(point)
        let position = position(at: point)
        hoverRow = position?.row
        hoverCell = position
        placeButtons()
    }

    /// «ОТКРЫТЬ» у названия строки под мышью и кнопка ссылки у ячейки под мышью.
    func placeButtons() {
        if let hoverRow, let titleColumn = content.columns.firstIndex(where: { $0.property.kind == .title }), grid?.editor?.position.row != hoverRow {
            let cell = cellRect(row: hoverRow, column: titleColumn)
            let size = GridOpenButton.size
            openButton.frame = NSRect(x: cell.maxX - size.width - 6, y: cell.midY - size.height / 2, width: size.width, height: size.height)
            openButton.isHidden = cell.width < size.width + 60
        } else {
            openButton.isHidden = true
        }
        if let hoverCell, grid?.editor == nil, let column = content.columns[safe: hoverCell.column],
           Self.linkKinds.contains(column.property.kind),
           let action = GridCellTypes.type(for: column.property.kind).hoverAction(cellValue(hoverCell)) {
            let cell = cellRect(row: hoverCell.row, column: hoverCell.column)
            linkButton.action = #selector(openHoveredLink)
            linkButton.configure(action)
            linkButton.frame = NSRect(x: cell.maxX - 30, y: cell.midY - 12, width: 24, height: 24)
            linkButton.isHidden = false
        } else {
            linkButton.isHidden = true
        }
    }

    /// Типы с кнопкой при наведении: значение читается, только когда мышь над такой ячейкой.
    static let linkKinds: Set<PropertyKind> = [.url, .email, .phone]

    private func cellValue(_ position: CellPosition) -> JSONValue? {
        guard let rowId = content.rowId(at: position.row), let property = content.columns[safe: position.column]?.property else { return nil }
        return try? content.store.write { try $0.cell(rowId: rowId, propertyId: property.id)?.value }
    }

    @objc private func openHoveredRow() {
        guard let hoverRow else { return }
        grid?.controller?.openRow(hoverRow)
    }

    @objc private func openHoveredLink() {
        guard let url = linkButton.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Мышь

    override func mouseDown(with event: NSEvent) {
        guard let grid, grid.controller != nil else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        didDrag = false
        if showsNewRow, newRowRect.contains(point) {
            grid.addRowAtBottom()
            return
        }
        guard let position = position(at: point) else {
            grid.clearSelection()
            window?.makeFirstResponder(self)
            return
        }
        if event.modifierFlags.contains(.option) {
            grid.controller?.openRow(position.row, mode: .sidePeek)
            return
        }
        if event.modifierFlags.contains(.shift), grid.selection != nil {
            grid.select(position, extending: true)
            return
        }
        let kind = content.columns[position.column].property.kind
        let wasSelected = grid.selection == CellSelection(position)
        grid.select(position)
        dragAnchor = position
        mouseDownPosition = position
        if CellKind.for(kind).editing == .toggle, checkboxHit(point, at: position) || wasSelected {
            grid.controller?.toggleCheckbox(row: position.row, column: position.column)
            mouseDownPosition = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grid, grid.controller != nil, let dragAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let position = nearestPosition(to: point) else { return }
        if position != dragAnchor || didDrag {
            didDrag = true
            var selection = CellSelection(dragAnchor)
            selection.extend(to: position)
            grid.selection = selection
            autoscroll(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragAnchor = nil; mouseDownPosition = nil }
        guard let grid, let position = mouseDownPosition, !didDrag, event.clickCount <= 2 else { return }
        // Щелчок по ячейке названия, текста, числа, ссылки, email, телефона — правка на месте (строку не открывает);
        // выбора, статуса, даты, файлов, связи — окно под ячейкой.
        if [.inPlace, .popup].contains(CellKind.for(content.columns[position.column].property.kind).editing) { grid.beginEditing() }
    }

    private func checkboxHit(_ point: NSPoint, at position: CellPosition) -> Bool {
        let cell = cellRect(row: position.row, column: position.column)
        let box = NSRect(x: cell.minX + Metrics.DatabaseGrid.cellHorizontalPadding - 4, y: cell.midY - 12, width: 26, height: 24)
        return box.contains(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let grid, grid.controller != nil, let position = position(at: convert(event.locationInWindow, from: nil)) else {
            return super.rightMouseDown(with: event)
        }
        if !grid.selectedRows.contains(position.row) { grid.select(position) }
        grid.onRowMenu?(position.row, grid.convert(event.locationInWindow, from: nil))
    }

    // MARK: Клавиши

    override func keyDown(with event: NSEvent) {
        guard let grid, let key = CellKey(event: event) else { return super.keyDown(with: event) }
        let command = CellKeyboard.command(for: key, modifiers: CellModifiers(event.modifierFlags), characters: event.characters,
                                           isEditing: false)
        if case .selectRow = command, grid.selection == nil, !grid.selectedRows.isEmpty {
            grid.selectedRows = []
            return
        }
        if !grid.perform(command) { super.keyDown(with: event) }
    }

    @objc func copy(_ sender: Any?) { grid?.copySelection() }
    @objc func cut(_ sender: Any?) { _ = grid?.perform(.cut) }
    @objc func paste(_ sender: Any?) { grid?.pasteClipboard() }
    @objc override func selectAll(_ sender: Any?) { grid?.selectAll() }
    @objc func delete(_ sender: Any?) { _ = grid?.perform(.erase) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): grid?.selection != nil || grid?.selectedRows.isEmpty == false
        case #selector(paste(_:)): grid?.selection != nil
        default: true
        }
    }
}

/// Строки интерфейса сетки.
enum GridStrings {
    static let newRow = "Новая строка"
    static let open = "ОТКРЫТЬ"
}

/// Значки сетки: SF Symbols нужного цвета, кэш по имени, размеру и цвету.
@MainActor
enum GridSymbols {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage {
        let key = "\(name)|\(size)|\(color.description)|\(weight.rawValue)"
        if let image = cache[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
        cache[key] = image
        return image
    }

    static var documentGlyph: NSImage { DocumentGlyph.image(size: 16, color: Palette.textSecondary) }
}

/// «ОТКРЫТЬ» у названия строки при наведении.
final class GridOpenButton: NSButton {
    static let size = NSSize(width: 78, height: 22)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        isBordered = false
        title = ""
        setAccessibilityLabel("Открыть строку")
        setAccessibilityIdentifier("database-row-open")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        Palette.popupMenuBackground.setFill()
        path.fill()
        Palette.border.setStroke()
        path.stroke()
        let icon = MainActor.assumeIsolated { GridSymbols.image("rectangle.righthalf.inset.filled", size: 10, color: Palette.textSecondary) }
        icon.draw(in: NSRect(x: 7, y: (bounds.height - 12) / 2, width: 13, height: 12))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                                                          .foregroundColor: Palette.textSecondary, .kern: 0.6]
        let title = NSAttributedString(string: GridStrings.open, attributes: attributes)
        let size = title.size()
        title.draw(at: NSPoint(x: 24, y: (bounds.height - size.height) / 2))
    }
}

/// Кнопка ссылки, email, телефона в ячейке при наведении.
final class GridLinkButton: NSButton {
    private(set) var url: URL?
    private var symbol = "arrow.up.right"

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setAccessibilityIdentifier("database-cell-link")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    func configure(_ action: CellHoverAction) {
        url = action.url
        symbol = action.symbol
        toolTip = action.tooltip
        setAccessibilityLabel(action.tooltip)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        Palette.popupMenuBackground.setFill()
        path.fill()
        Palette.border.setStroke()
        path.stroke()
        let icon = MainActor.assumeIsolated { GridSymbols.image(symbol, size: 11, color: Palette.textSecondary) }
        icon.draw(in: NSRect(x: (bounds.width - 13) / 2, y: (bounds.height - 13) / 2, width: 13, height: 13))
    }
}
