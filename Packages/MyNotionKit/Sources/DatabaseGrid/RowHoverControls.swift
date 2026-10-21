import AppKit
import VisualStyle

/// Ручки строки под мышью слева от таблицы (contracts/database-ui.md, «Строки»): «+» — новая строка ниже, «⠿» — тянуть
/// (щелчок — меню строки), флажок — выбрать строку. Слева от таблицы места нет — в сетке, вложенной в страницу, вид
/// ставится в документ прокрутки страницы, иначе — в саму сетку.
@MainActor
final class RowHoverControls: NSView {
    weak var grid: DatabaseGridView?
    static let size = NSSize(width: 66, height: Metrics.DatabaseGrid.rowHeight)
    private var row: Int?
    private var hoverPart: Int? { didSet { if hoverPart != oldValue { needsDisplay = true } } }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        isHidden = true
        setAccessibilityIdentifier("database-row-handles")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    private var host: NSView? {
        guard let grid else { return nil }
        return grid.scrollView.enclosingScrollView?.documentView ?? grid
    }

    /// Встать у строки под мышью или спрятаться.
    func update() {
        guard let grid, grid.controller != nil, let row = grid.documentView.hoverRow, let host, grid.window != nil else {
            isHidden = true
            row = nil
            return
        }
        if superview !== host {
            removeFromSuperview()
            host.addSubview(self)
        }
        self.row = row
        let rowRect = grid.documentView.rowRect(row)
        let inHost = host.convert(rowRect, from: grid.documentView)
        frame = NSRect(x: inHost.minX - Self.size.width - 2, y: inHost.minY, width: Self.size.width, height: Self.size.height)
        // Строка уехала из видимой части сетки (прокрутка вбок, верх таблицы) — ручек нет.
        let visible = grid.convert(grid.bounds, to: host)
        isHidden = inHost.maxY < visible.minY + Metrics.DatabaseGrid.headerHeight || inHost.minY > visible.maxY
        needsDisplay = true
    }

    func contains(screenPoint: NSPoint, in window: NSWindow) -> Bool {
        guard !isHidden, self.window === window else { return false }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return bounds.contains(point)
    }

    private func part(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        return min(2, Int(point.x / (bounds.width / 3)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let partWidth = bounds.width / 3
        let selected = row.map { grid?.selectedRows.contains($0) ?? false } ?? false
        for (index, name) in ["plus", "circle.grid.2x3.fill", selected ? "checkmark.square.fill" : "square"].enumerated() {
            let rect = NSRect(x: CGFloat(index) * partWidth, y: (bounds.height - 22) / 2, width: partWidth, height: 22)
            if hoverPart == index {
                Palette.hoverBackground.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 0), xRadius: 4, yRadius: 4).fill()
            }
            let color = index == 2 && selected ? Palette.checkboxChecked : Palette.handleIcon
            let icon = GridSymbols.image(name, size: index == 1 ? 9 : 13, color: color, weight: .medium)
            icon.draw(in: NSRect(x: rect.midX - icon.size.width / 2, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
        }
    }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { hoverPart = part(at: convert(event.locationInWindow, from: nil)) }

    override func mouseExited(with event: NSEvent) {
        hoverPart = nil
        guard let grid, let window else { return }
        let point = grid.documentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !grid.documentView.visibleRect.contains(point) { grid.documentView.hover(at: nil) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let grid, let row, let part = part(at: convert(event.locationInWindow, from: nil)) else { return }
        switch part {
        case 0: grid.addRow(after: row)
        case 1: dragRow(row, from: event)
        default: grid.toggleRowSelection(row)
        }
    }

    /// «⠿»: протяжка переставляет строку (или выбранные строки) в ручном порядке вида, щелчок — меню строки.
    private func dragRow(_ row: Int, from event: NSEvent) {
        guard let grid, let window else { return }
        let document = grid.documentView
        let start = event.locationInWindow
        var moved = false
        var target: Int?
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { event, stop in
            guard let event else { return }
            if event.type == .leftMouseUp {
                stop.pointee = true
                return
            }
            if !moved, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4 { return }
            moved = true
            let point = document.convert(event.locationInWindow, from: nil)
            let index = Int(((point.y - Metrics.DatabaseGrid.headerHeight) / Metrics.DatabaseGrid.rowHeight).rounded())
            target = min(max(index, 0), grid.content.rowCount)
            document.dropRow = target
            document.autoscroll(with: event)
        }
        document.dropRow = nil
        if moved, let target {
            let rows = grid.selectedRows.contains(row) ? grid.selectedRows.sorted() : [row]
            grid.controller?.moveRows(rows, before: target)
        } else if !moved {
            let point = grid.convert(NSPoint(x: frame.maxX, y: 0), from: superview)
            grid.onRowMenu?(row, NSPoint(x: grid.convert(bounds, from: self).maxX, y: point.y + grid.convert(bounds, from: self).minY))
        }
    }
}
