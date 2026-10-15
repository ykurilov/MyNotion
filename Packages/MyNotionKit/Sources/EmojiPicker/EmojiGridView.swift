import AppKit
import VisualStyle

/// Сетка эмодзи: разделы с заголовками (или результаты поиска без них), по 12 в ряд. Под мышью и подсвеченный
/// стрелками — на подложке; щелчок ставит эмодзи.
@MainActor
final class EmojiGridView: NSView {
    private struct Section {
        let section: EmojiSection?
        let emojis: [String]
        let top: CGFloat
        let gridTop: CGFloat
    }

    private var layoutSections: [Section] = []
    private(set) var allEmojis: [String] = []
    private var indexByEmoji: [String: Int] = [:]
    private(set) var contentHeight: CGFloat = 0
    /// Поиск ничего не нашёл.
    private(set) var emptyMessage: String?
    private(set) var highlighted: String? { didSet { if highlighted != oldValue { needsDisplay = true } } }
    private var hovered: String? { didSet { if hovered != oldValue { needsDisplay = true } } }
    var onChoose: ((String) -> Void)?

    override var isFlipped: Bool { true }

    var sections: [EmojiSection] { layoutSections.compactMap(\.section) }

    func showSections(_ sections: [(EmojiSection, [String])]) {
        let metrics = Metrics.EmojiPicker.self
        var y: CGFloat = 0
        layoutSections = sections.map { section, emojis in
            let top = y
            y += metrics.sectionHeaderHeight + rowsHeight(emojis.count)
            return Section(section: section, emojis: emojis, top: top, gridTop: top + metrics.sectionHeaderHeight)
        }
        finish(height: y, highlighted: nil, emptyMessage: nil)
    }

    func showResults(_ emojis: [String]) {
        let top = Metrics.EmojiPicker.searchResultsTopPadding
        layoutSections = [Section(section: nil, emojis: emojis, top: 0, gridTop: top)]
        finish(height: top + rowsHeight(emojis.count) + top, highlighted: emojis.first,
               emptyMessage: emojis.isEmpty ? "Ничего не найдено" : nil)
    }

    private func rowsHeight(_ count: Int) -> CGFloat {
        let columns = Metrics.EmojiPicker.columns
        return CGFloat((count + columns - 1) / columns) * Metrics.EmojiPicker.cellSize
    }

    private func finish(height: CGFloat, highlighted: String?, emptyMessage: String?) {
        allEmojis = layoutSections.flatMap(\.emojis)
        indexByEmoji = [:]
        for (index, emoji) in allEmojis.enumerated() where indexByEmoji[emoji] == nil { indexByEmoji[emoji] = index }
        contentHeight = height
        self.highlighted = highlighted
        self.emptyMessage = emptyMessage
        hovered = nil
        needsDisplay = true
    }

    func emojis(in section: EmojiSection) -> [String] {
        layoutSections.first { $0.section == section }?.emojis ?? []
    }

    func top(of section: EmojiSection) -> CGFloat? {
        layoutSections.first { $0.section == section }?.top
    }

    func section(atY y: CGFloat) -> EmojiSection? {
        layoutSections.last { $0.top <= y }?.section ?? layoutSections.first?.section
    }

    func cellFrame(of emoji: String) -> NSRect? {
        for section in layoutSections {
            guard let index = section.emojis.firstIndex(of: emoji) else { continue }
            return cellFrame(index, in: section)
        }
        return nil
    }

    private func cellFrame(_ index: Int, in section: Section) -> NSRect {
        let metrics = Metrics.EmojiPicker.self
        let column = index % metrics.columns, row = index / metrics.columns
        return NSRect(x: metrics.gridPadding + CGFloat(column) * metrics.cellSize, y: section.gridTop + CGFloat(row) * metrics.cellSize,
                      width: metrics.cellSize, height: metrics.cellSize)
    }

    func emoji(at point: NSPoint) -> String? {
        let metrics = Metrics.EmojiPicker.self
        guard let section = layoutSections.last(where: { $0.gridTop <= point.y }) else { return nil }
        let column = Int(floor((point.x - metrics.gridPadding) / metrics.cellSize))
        let row = Int(floor((point.y - section.gridTop) / metrics.cellSize))
        guard (0..<metrics.columns).contains(column), row >= 0 else { return nil }
        let index = row * metrics.columns + column
        return section.emojis.indices.contains(index) ? section.emojis[index] : nil
    }

    func moveHighlight(by step: Int) {
        guard !allEmojis.isEmpty else { return }
        let current = highlighted.flatMap { indexByEmoji[$0] }
        let next = current.map { min(max($0 + step, 0), allEmojis.count - 1) } ?? 0
        highlighted = allEmojis[next]
    }

    func choose(_ emoji: String) {
        onChoose?(emoji)
    }

    // MARK: Мышь

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { hovered = emoji(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if let emoji = emoji(at: convert(event.locationInWindow, from: nil)) { choose(emoji) }
    }

    // MARK: Вид

    override func draw(_ dirtyRect: NSRect) {
        let metrics = Metrics.EmojiPicker.self
        let titleStyle = Typography.popupMenuSectionHeader
        if let emptyMessage {
            drawTitle(emptyMessage, top: 0, style: titleStyle)
            return
        }
        let emojiAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: metrics.emojiFontSize)]
        for section in layoutSections {
            let bottom = section.gridTop + rowsHeight(section.emojis.count)
            guard bottom >= dirtyRect.minY, section.top <= dirtyRect.maxY else { continue }
            if let title = section.section?.title { drawTitle(title, top: section.top, style: titleStyle) }
            for (index, emoji) in section.emojis.enumerated() {
                let cell = cellFrame(index, in: section)
                guard cell.intersects(dirtyRect) else { continue }
                if emoji == highlighted || emoji == hovered {
                    Palette.hoverBackground.setFill()
                    NSBezierPath(roundedRect: cell, xRadius: metrics.cellCornerRadius, yRadius: metrics.cellCornerRadius).fill()
                }
                let text = NSAttributedString(string: emoji, attributes: emojiAttributes)
                let size = text.size()
                text.draw(at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2))
            }
        }
    }

    private func drawTitle(_ title: String, top: CGFloat, style: TextLineStyle) {
        let metrics = Metrics.EmojiPicker.self
        NSAttributedString(string: title, attributes: [.font: style.font, .foregroundColor: Palette.emojiSectionTitle])
            .draw(in: NSRect(x: metrics.sectionTitleX, y: top + metrics.sectionTitleCenterY - style.lineHeight / 2,
                             width: bounds.width - 2 * metrics.sectionTitleX, height: style.lineHeight))
    }
}

/// Строка значков разделов внизу окна: щелчок прокручивает к разделу; текущий — на подложке; «Недавние» без
/// недавних неактивны (бледнее), как у Notion.
@MainActor
final class EmojiSectionBar: NSView {
    let sections = EmojiSection.allCases
    var enabled: Set<EmojiSection> = Set(EmojiSection.allCases) { didSet { needsDisplay = true } }
    var current: EmojiSection = .people { didSet { needsDisplay = true } }
    var onSelect: ((EmojiSection) -> Void)?

    override var isFlipped: Bool { true }

    func isEnabled(_ section: EmojiSection) -> Bool { enabled.contains(section) }

    func press(_ section: EmojiSection) {
        guard isEnabled(section) else { return }
        onSelect?(section)
    }

    private func center(of index: Int) -> NSPoint {
        let metrics = Metrics.EmojiPicker.self
        return NSPoint(x: metrics.firstSectionIconCenterX + CGFloat(index) * metrics.sectionIconPitch, y: metrics.sectionIconCenterY)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let half = Metrics.EmojiPicker.sectionHighlightSize / 2
        if let index = sections.indices.first(where: { abs(center(of: $0).x - point.x) <= half }) { press(sections[index]) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let metrics = Metrics.EmojiPicker.self
        for (index, section) in sections.enumerated() {
            let center = center(of: index)
            if section == current {
                let size = metrics.sectionHighlightSize
                Palette.hoverBackground.setFill()
                NSBezierPath(roundedRect: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
                             xRadius: metrics.cellCornerRadius, yRadius: metrics.cellCornerRadius).fill()
            }
            EmojiPickerSymbol.draw(section.symbolName, size: metrics.sectionIconSize,
                                   color: isEnabled(section) ? Palette.emojiPickerIcon : Palette.emojiPickerIconDisabled, center: center)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Разделы" }
}
