import AppKit
import CoreText
import Databases
import NotesCore
import VisualStyle

/// Сетка таблицы базы (research R4): документ во всю высоту таблицы в `NSScrollView`; рисуются только строки в видимой
/// полосе — слой документа делится AppKit на плитки, при прокрутке дорисовываются только открывшиеся; текст —
/// Core Text через кэш строк. Шапка колонок закреплена сверху (плавающий вид прокрутки).
/// Встроенная база (`scrollsVertically == false`) — та же сетка высотой по строкам, вертикальная прокрутка — у страницы.
@MainActor
public final class DatabaseGridView: NSView {
    public let content: GridContent
    public let scrollView: NSScrollView
    let documentView: GridDocumentView
    let headerView: GridHeaderView
    public let scrollsVertically: Bool

    public init(content: GridContent, scrollsVertically: Bool = true) {
        self.content = content
        self.scrollsVertically = scrollsVertically
        scrollView = scrollsVertically ? NSScrollView() : PassThroughScrollView()
        documentView = GridDocumentView(content: content)
        headerView = GridHeaderView(content: content)
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = scrollsVertically
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = scrollsVertically ? .automatic : .none
        scrollView.documentView = documentView
        scrollView.addFloatingSubview(headerView, for: .vertical)
        addSubview(scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        content.onRowsLoaded = { [weak self] rows in self?.documentView.setNeedsDisplay(rows: rows) }
        reloadData()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    public override var isFlipped: Bool { true }

    /// Высота всей таблицы (шапка и строки) — для встроенной базы.
    public var fittingHeight: CGFloat { Metrics.DatabaseGrid.headerHeight + CGFloat(content.rowCount) * Metrics.DatabaseGrid.rowHeight + 1 }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        documentView.updateSize(minimumWidth: scrollView.contentSize.width)
        headerView.frame = NSRect(x: 0, y: 0, width: documentView.frame.width, height: Metrics.DatabaseGrid.headerHeight)
    }

    /// Новые строки или колонки: перерисовать всё.
    public func reloadData() {
        documentView.updateSize(minimumWidth: scrollView.contentSize.width)
        headerView.frame = NSRect(x: 0, y: 0, width: documentView.frame.width, height: Metrics.DatabaseGrid.headerHeight)
        documentView.needsDisplay = true
        headerView.needsDisplay = true
        content.prefetch(around: visibleRows)
    }

    /// Перечитать и перерисовать строку.
    public func reloadRow(at index: Int) {
        content.reloadRow(index)
        documentView.setNeedsDisplay(rows: index..<index + 1)
    }

    /// Строки в видимой части.
    public var visibleRows: Range<Int> { documentView.rows(in: scrollView.documentVisibleRect) }

    /// Рамка ячейки в координатах сетки (для проб и редактора ячейки).
    public func cellRect(row: Int, column: Int) -> NSRect {
        convert(documentView.cellRect(row: row, column: column), from: documentView)
    }

    /// Прокрутить так, чтобы строка `index` была у верха.
    public func scroll(toRow index: Int) {
        let y = CGFloat(index) * Metrics.DatabaseGrid.rowHeight
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @objc private func visibleAreaChanged() {
        content.prefetch(around: visibleRows)
    }
}

/// Прокрутка встроенной базы: колёсико по вертикали уходит странице.
final class PassThroughScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

/// Документ сетки: строки под шапкой, каждая рисуется в своей полосе.
@MainActor
final class GridDocumentView: NSView {
    let content: GridContent
    let text = GridTextRenderer()

    init(content: GridContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    var tableWidth: CGFloat { content.columns.reduce(0) { $0 + $1.width } }

    func updateSize(minimumWidth: CGFloat) {
        let height = Metrics.DatabaseGrid.headerHeight + CGFloat(content.rowCount) * Metrics.DatabaseGrid.rowHeight + 1
        let size = NSSize(width: max(tableWidth + 1, minimumWidth), height: height)
        if frame.size != size { setFrameSize(size) }
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
        rect.size.width = content.columns[column].width
        return rect
    }

    func setNeedsDisplay(rows: Range<Int>) {
        guard !rows.isEmpty else { return }
        let rect = rowRect(rows.lowerBound).union(rowRect(rows.upperBound - 1))
        setNeedsDisplay(rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rows = rows(in: dirtyRect)
        let lineColor = Palette.databaseGridLine.cgColor
        context.setFillColor(lineColor)
        let lineWidth = Metrics.DatabaseGrid.lineWidth
        let tableWidth = tableWidth
        // Колонки, попавшие в полосу.
        var columnRanges: [(index: Int, minX: CGFloat, width: CGFloat)] = []
        var x: CGFloat = 0
        for (index, column) in content.columns.enumerated() {
            if x + column.width >= dirtyRect.minX, x <= dirtyRect.maxX { columnRanges.append((index, x, column.width)) }
            x += column.width
        }
        for index in rows {
            let rect = rowRect(index)
            context.fill(CGRect(x: 0, y: rect.maxY - lineWidth, width: tableWidth, height: lineWidth))
            guard let row = content.row(at: index) else { continue }
            for (column, minX, width) in columnRanges {
                let cell = CGRect(x: minX, y: rect.minY, width: width, height: rect.height - lineWidth)
                if column > 0 { context.fill(CGRect(x: minX, y: rect.minY, width: lineWidth, height: rect.height)) }
                draw(row.cells[column], in: cell, column: content.columns[column], icon: column == 0 ? row.icon : nil, context: context)
            }
            context.setFillColor(lineColor)
        }
        // Правая граница последней колонки.
        if tableWidth >= dirtyRect.minX, tableWidth <= dirtyRect.maxX, let first = rows.first, let last = rows.last {
            context.fill(CGRect(x: tableWidth, y: rowRect(first).minY, width: lineWidth, height: rowRect(last).maxY - rowRect(first).minY))
        }
    }

    private func draw(_ cell: CellPresentation, in rect: CGRect, column: GridColumn, icon: String?, context: CGContext) {
        let padding = Metrics.DatabaseGrid.cellHorizontalPadding
        let inner = rect.insetBy(dx: padding, dy: 0)
        switch cell {
        case .empty: break
        case .text(let string):
            var textRect = inner
            if let icon {
                text.draw(icon, in: textRect, color: Palette.textPrimary, alignment: .left, context: context)
                textRect.origin.x += 22
                textRect.size.width -= 22
            }
            text.draw(string, in: textRect, color: Palette.textPrimary, alignment: column.alignsRight ? .right : .left,
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
        }
    }
}

/// Шапка колонок: название свойства серым.
@MainActor
final class GridHeaderView: NSView {
    let content: GridContent
    let text = GridTextRenderer()

    init(content: GridContent) {
        self.content = content
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(Palette.pageBackground.cgColor)
        context.fill(bounds)
        context.setFillColor(Palette.databaseGridLine.cgColor)
        let line = Metrics.DatabaseGrid.lineWidth
        var x: CGFloat = 0
        for (index, column) in content.columns.enumerated() {
            if index > 0 { context.fill(CGRect(x: x, y: 0, width: line, height: bounds.height)) }
            text.draw(column.property.name, in: CGRect(x: x + Metrics.DatabaseGrid.cellHorizontalPadding, y: 0,
                                                       width: column.width - 2 * Metrics.DatabaseGrid.cellHorizontalPadding, height: bounds.height),
                      color: Palette.textSecondary, alignment: .left, context: context)
            context.setFillColor(Palette.databaseGridLine.cgColor)
            x += column.width
        }
        context.fill(CGRect(x: 0, y: 0, width: x, height: line))
        context.fill(CGRect(x: 0, y: bounds.height - line, width: x, height: line))
    }
}

/// Текст ячеек Core Text: строки `CTLine` кэшируются по тексту, цвету и начертанию; длинный текст обрезается «…».
@MainActor
final class GridTextRenderer {
    enum Alignment { case left, right }

    private struct Key: Hashable {
        let text: String
        let weight: NSFont.Weight.RawValue
        let width: Int
    }

    private var lines: [Key: CTLine] = [:]
    private var widths: [String: CGFloat] = [:]
    private var fonts: [NSFont.Weight.RawValue: NSFont] = [:]

    private func font(_ weight: NSFont.Weight) -> NSFont {
        if let font = fonts[weight.rawValue] { return font }
        let font = NSFont.systemFont(ofSize: Metrics.DatabaseGrid.fontSize, weight: weight)
        fonts[weight.rawValue] = font
        return font
    }

    func width(_ text: String, size: CGFloat) -> CGFloat {
        if let width = widths[text] { return width }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font(.regular)]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if widths.count > 20_000 { widths.removeAll() }
        widths[text] = width
        return width
    }

    func draw(_ text: String, in rect: CGRect, color: NSColor, alignment: Alignment, weight: NSFont.Weight = .regular, context: CGContext) {
        guard rect.width > 4, !text.isEmpty else { return }
        let key = Key(text: text, weight: weight.rawValue, width: Int(rect.width))
        let line: CTLine
        if let cached = lines[key] {
            line = cached
        } else {
            // Цвет — из контекста (`foregroundColorFromContext`): одна строка служит обеим темам и всем цветам.
            let attributed = NSAttributedString(string: text.replacingOccurrences(of: "\n", with: " "),
                                                attributes: [.font: font(weight), NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
            let full = CTLineCreateWithAttributedString(attributed)
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [.font: font(weight),
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
            line = CTLineCreateTruncatedLine(full, Double(rect.width), .end, ellipsis) ?? full
            if lines.count > 20_000 { lines.removeAll() }
            lines[key] = line
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let x = alignment == .right ? rect.maxX - width : rect.minX
        // Вид перевёрнут: Core Text рисует снизу вверх — переворачиваем на время строки.
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.textMatrix = .identity
        context.translateBy(x: x, y: rect.midY + (ascent - descent) / 2)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
