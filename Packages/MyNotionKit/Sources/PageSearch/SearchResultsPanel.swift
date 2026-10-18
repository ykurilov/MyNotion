import AppKit
import NotesCore
import VisualStyle

/// Окно выдачи без рамки: карточка как у всплывающих меню и место под тень. Ключевым не становится —
/// курсор и ввод остаются в поле поиска.
@MainActor
final class SearchResultsPanel: NSPanel {
    static let shadowMargin: CGFloat = 32

    let resultsView = SearchResultsView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        isReleasedWhenClosed = false
        contentView = SearchResultsCard(resultsView: resultsView)
        setAccessibilityIdentifier("search-results")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Карточка с тенью; строки — в прокрутке внутри неё.
@MainActor
private final class SearchResultsCard: NSView {
    private let scrollView = NSScrollView()

    init(resultsView: SearchResultsView) {
        super.init(frame: .zero)
        scrollView.documentView = resultsView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Metrics.SearchResults.verticalPadding, left: 0,
                                                bottom: Metrics.SearchResults.verticalPadding, right: 0)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private var card: NSRect { bounds.insetBy(dx: SearchResultsPanel.shadowMargin, dy: SearchResultsPanel.shadowMargin) }

    override func layout() {
        super.layout()
        scrollView.frame = card
        guard let resultsView = scrollView.documentView as? SearchResultsView else { return }
        resultsView.frame.size = NSSize(width: card.width, height: resultsView.contentHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        PopupSurface.draw(card: card)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Строки выдачи: иконка, название с найденным синим, путь родителей серым, кусок текста с найденным словом.
/// Под мышью и выбранная стрелками строка — подложка hoverBackground; пусто — «Ничего не найдено».
@MainActor
final class SearchResultsView: NSView {
    static let emptyText = "Ничего не найдено"

    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private(set) var results: [PageSearchResult] = []
    var selectedIndex = 0 {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityIdentifier("search-results-list")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var isFlipped: Bool { true }

    func show(_ results: [PageSearchResult], selectedIndex: Int) {
        self.results = results
        self.selectedIndex = selectedIndex
        frame.size.height = contentHeight
        setAccessibilityLabel(results.isEmpty ? Self.emptyText : results.map(\.title).joined(separator: ", "))
        needsDisplay = true
        scrollSelectionToVisible()
    }

    /// Высота строк без полей карточки.
    var contentHeight: CGFloat {
        results.isEmpty ? Metrics.SearchResults.emptyRowHeight : results.map(Self.rowHeight).reduce(0, +)
    }

    /// Высота карточки, в которую строки влезают целиком.
    var preferredCardHeight: CGFloat { contentHeight + 2 * Metrics.SearchResults.verticalPadding }

    static func rowHeight(_ result: PageSearchResult) -> CGFloat {
        let metrics = Metrics.SearchResults.self
        var height = 2 * metrics.rowVerticalPadding + metrics.titleLineHeight
        if !result.path.isEmpty { height += metrics.detailLineHeight }
        if result.snippet != nil { height += metrics.detailLineHeight }
        return height
    }

    private func rowRect(_ index: Int) -> NSRect {
        let top = results.prefix(index).map(Self.rowHeight).reduce(0, +)
        let inset = Metrics.PopupMenu.rowInset
        return NSRect(x: inset, y: top, width: bounds.width - 2 * inset, height: Self.rowHeight(results[index]))
    }

    func scrollSelectionToVisible() {
        guard results.indices.contains(selectedIndex) else { return }
        scrollToVisible(rowRect(selectedIndex))
    }

    // MARK: Мышь

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        if let index = index(at: event), index != selectedIndex { onHover?(index) }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = index(at: event) { onClick?(index) }
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return results.indices.first { rowRect($0).contains(point) }
    }

    // MARK: Рисование

    override func draw(_ dirtyRect: NSRect) {
        let metrics = Metrics.SearchResults.self
        guard !results.isEmpty else {
            let line = Typography.popupMenuTitle
            let x = Metrics.PopupMenu.rowInset + Metrics.PopupMenu.rowHorizontalPadding
            draw(NSAttributedString(string: Self.emptyText, attributes: [.font: line.font, .foregroundColor: Palette.textSecondary]),
                 in: NSRect(x: x, y: (metrics.emptyRowHeight - line.lineHeight) / 2, width: bounds.width - 2 * x, height: line.lineHeight))
            return
        }
        for index in results.indices {
            let row = rowRect(index)
            guard row.intersects(dirtyRect) else { continue }
            if index == selectedIndex {
                Palette.hoverBackground.setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: 0, dy: Metrics.PopupMenu.rowHighlightInset),
                             xRadius: Metrics.PopupMenu.rowCornerRadius, yRadius: Metrics.PopupMenu.rowCornerRadius).fill()
            }
            drawRow(results[index], in: row)
        }
    }

    private func drawRow(_ result: PageSearchResult, in row: NSRect) {
        let metrics = Metrics.SearchResults.self
        var y = row.minY + metrics.rowVerticalPadding
        let iconRect = NSRect(x: row.minX + Metrics.PopupMenu.rowHorizontalPadding,
                              y: y + (metrics.titleLineHeight - metrics.iconSize) / 2, width: metrics.iconSize, height: metrics.iconSize)
        drawIcon(result.icon, in: iconRect)

        let textX = row.minX + metrics.textX
        let textWidth = row.maxX - metrics.rowTrailingPadding - textX
        let title = result.title.isEmpty ? Page.untitledTitle : result.title
        draw(highlighted(title, ranges: result.title.isEmpty ? [] : result.titleHighlights,
                         style: Typography.searchResultTitle, color: Palette.textPrimary),
             in: NSRect(x: textX, y: y, width: textWidth, height: metrics.titleLineHeight))
        y += metrics.titleLineHeight
        if !result.path.isEmpty {
            draw(NSAttributedString(string: result.path.joined(separator: " / "),
                                    attributes: attributes(Typography.searchResultDetail, color: Palette.textSecondary)),
                 in: NSRect(x: textX, y: y, width: textWidth, height: metrics.detailLineHeight))
            y += metrics.detailLineHeight
        }
        if let snippet = result.snippet {
            draw(highlighted(snippet.text, ranges: snippet.highlights, style: Typography.searchResultDetail, color: Palette.sidebarText),
                 in: NSRect(x: textX, y: y, width: textWidth, height: metrics.detailLineHeight))
        }
    }

    private func drawIcon(_ icon: String?, in rect: NSRect) {
        guard let icon else {
            DocumentGlyph.image(size: rect.width, color: Palette.sidebarIcon).draw(in: rect)
            return
        }
        let string = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: Metrics.SearchResults.iconFontSize)])
        let size = string.size()
        string.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func attributes(_ style: TextLineStyle, color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = style.paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        paragraph.lineBreakMode = .byTruncatingTail
        return [.font: style.font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private func highlighted(_ text: String, ranges: [NSRange], style: TextLineStyle, color: NSColor) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text, attributes: attributes(style, color: color))
        for range in ranges where NSMaxRange(range) <= string.length {
            string.addAttribute(.foregroundColor, value: Palette.searchHighlight, range: range)
        }
        return string
    }

    private func draw(_ string: NSAttributedString, in rect: NSRect) {
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
