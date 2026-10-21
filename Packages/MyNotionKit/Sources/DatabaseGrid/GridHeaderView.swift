import AppKit
import Databases
import NotesCore
import VisualStyle

/// Шапка колонок (contracts/database-ui.md, «Шапка колонок»): значок типа и название серым; щелчок — меню колонки,
/// протяжка края — ширина (запись по отпусканию), перетаскивание — порядок колонок вида; в конце «+» и «•••».
@MainActor
final class GridHeaderView: NSView {
    let content: GridContent
    let text = GridTextRenderer()
    weak var grid: DatabaseGridView?
    static let buttonWidth: CGFloat = 32
    static var trailingButtonsWidth: CGFloat { buttonWidth * 2 }
    /// Край колонки ловится в стольких точках по обе стороны.
    static let edgeSlop: CGFloat = 4

    private enum Drag {
        case resize(column: Int, startX: CGFloat, startWidth: CGFloat)
        case move(column: Int, startX: CGFloat, target: Int?)
    }

    private var drag: Drag?
    private var hoverColumn: Int? { didSet { if hoverColumn != oldValue { needsDisplay = true } } }
    private var hoverButton: Int? { didSet { if hoverButton != oldValue { needsDisplay = true } } }

    init(content: GridContent) {
        self.content = content
        super.init(frame: .zero)
        setAccessibilityIdentifier("database-grid-header")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    private var interactive: Bool { grid?.controller != nil }

    var tableWidth: CGFloat { content.columns.reduce(0) { $0 + $1.width } }
    var addRect: NSRect { NSRect(x: tableWidth, y: 0, width: Self.buttonWidth, height: bounds.height) }
    var moreRect: NSRect { NSRect(x: tableWidth + Self.buttonWidth, y: 0, width: Self.buttonWidth, height: bounds.height) }

    func columnRect(_ index: Int) -> NSRect {
        let x = content.columns.prefix(index).reduce(0) { $0 + $1.width }
        return NSRect(x: x, y: 0, width: content.columns[index].width, height: bounds.height)
    }

    private func column(at x: CGFloat) -> Int? {
        var left: CGFloat = 0
        for (index, column) in content.columns.enumerated() {
            if x >= left, x < left + column.width { return index }
            left += column.width
        }
        return nil
    }

    /// Колонка, чей правый край под точкой.
    private func edge(at x: CGFloat) -> Int? {
        var right: CGFloat = 0
        for (index, column) in content.columns.enumerated() {
            right += column.width
            if abs(x - right) <= Self.edgeSlop { return index }
        }
        return nil
    }

    // MARK: Рисование

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(Palette.pageBackground.cgColor)
        context.fill(bounds)
        let line = Metrics.DatabaseGrid.lineWidth
        var x: CGFloat = 0
        let padding = Metrics.DatabaseGrid.cellHorizontalPadding
        for (index, column) in content.columns.enumerated() {
            let rect = NSRect(x: x, y: 0, width: column.width, height: bounds.height)
            if interactive, hoverColumn == index, drag == nil {
                context.setFillColor(Palette.hoverBackground.cgColor)
                context.fill(rect)
            }
            context.setFillColor(Palette.databaseGridLine.cgColor)
            if index > 0 { context.fill(CGRect(x: x, y: 0, width: line, height: bounds.height)) }
            let symbol = CellKind.for(column.property.kind).symbol
            let icon = GridSymbols.image(symbol, size: 12, color: Palette.textSecondary)
            let iconRect = NSRect(x: x + padding, y: rect.midY - 8, width: 16, height: 16)
            icon.draw(in: iconRect.insetBy(dx: (16 - min(16, icon.size.width)) / 2, dy: (16 - min(16, icon.size.height)) / 2))
            text.draw(column.property.name, in: CGRect(x: iconRect.maxX + 6, y: 0, width: column.width - padding * 2 - 22, height: bounds.height),
                      color: Palette.textSecondary, alignment: .left, context: context)
            x += column.width
        }
        context.setFillColor(Palette.databaseGridLine.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: x, height: line))
        context.fill(CGRect(x: 0, y: bounds.height - line, width: x, height: line))
        if x > 0 { context.fill(CGRect(x: x, y: 0, width: line, height: bounds.height)) }
        if interactive {
            for (index, (rect, name)) in [(addRect, "plus"), (moreRect, "ellipsis")].enumerated() {
                if hoverButton == index {
                    context.setFillColor(Palette.hoverBackground.cgColor)
                    context.addPath(CGPath(roundedRect: rect.insetBy(dx: 4, dy: 6), cornerWidth: 4, cornerHeight: 4, transform: nil))
                    context.fillPath()
                }
                let icon = GridSymbols.image(name, size: 13, color: Palette.textSecondary)
                icon.draw(in: NSRect(x: rect.midX - icon.size.width / 2, y: rect.midY - icon.size.height / 2, width: icon.size.width,
                                     height: icon.size.height))
            }
        }
        if case .move(let column, _, let target?) = drag {
            let targetX = target < content.columns.count ? columnRect(target).minX : tableWidth
            context.setFillColor(Palette.dropIndicator.cgColor)
            context.fill(CGRect(x: targetX - 1.5, y: 0, width: 3, height: bounds.height))
            _ = column
        }
    }

    // MARK: Мышь

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard interactive else { return }
        let point = convert(event.locationInWindow, from: nil)
        hoverColumn = edge(at: point.x) == nil ? column(at: point.x) : nil
        hoverButton = addRect.contains(point) ? 0 : moreRect.contains(point) ? 1 : nil
        (edge(at: point.x) != nil ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard interactive else { return super.cursorUpdate(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        (edge(at: point.x) != nil ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        hoverColumn = nil
        hoverButton = nil
        if drag == nil { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive, let grid else { return }
        let point = convert(event.locationInWindow, from: nil)
        grid.commitEditing(then: nil)
        if let edgeColumn = edge(at: point.x) {
            drag = .resize(column: edgeColumn, startX: point.x, startWidth: content.columns[edgeColumn].width)
        } else if let column = column(at: point.x) {
            drag = .move(column: column, startX: point.x, target: nil)
        } else if addRect.contains(point) {
            grid.onAddProperty?(grid.convert(addRect, from: self))
        } else if moreRect.contains(point) {
            grid.onViewSettings?(grid.convert(moreRect, from: self))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grid else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .resize(let column, let startX, let startWidth):
            content.setWidth(max(CGFloat(DatabaseColumns.minimumWidth), (startWidth + point.x - startX).rounded()), column: column)
            grid.needsLayout = true
            grid.documentView.needsDisplay = true
            needsDisplay = true
        case .move(let column, let startX, _):
            // «Название» всегда первое: его не тащат и перед ним не ставят.
            guard abs(point.x - startX) > 4, content.columns[column].property.kind != .title else { return }
            var target = content.columns.count
            var left: CGFloat = 0
            for (index, item) in content.columns.enumerated() {
                if point.x < left + item.width / 2 { target = index; break }
                left += item.width
            }
            drag = .move(column: column, startX: startX, target: max(target, 1))
            needsDisplay = true
            autoscroll(with: event)
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = nil
            needsDisplay = true
        }
        guard let grid, let controller = grid.controller else { return }
        switch drag {
        case .resize(let column, _, _):
            controller.setWidth(content.columns[column].width, column: column)
        case .move(let column, _, let target?):
            // Индекс среди видимых колонок после того, как колонку вынули.
            let index = target > column ? target - 1 : target
            if index != column { controller.moveColumn(column, to: index) }
        case .move(let column, _, nil):
            grid.onColumnMenu?(content.columns[column].property, grid.convert(columnRect(column), from: self))
        case nil: break
        }
    }
}
